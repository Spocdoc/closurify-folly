ug = require 'uglify-js-fork'
fs = require 'fs'
async = require 'async'
path = require 'path'
SourceMap = require './sourcemap'
closure = compile: require './compile'
removeDebug = require './remove_debug'
buildTree = require './build_tree'
utils = _ = require 'underscore-folly'
replaceGlobal = require './replace_global'
replaceRequires = require './replace_requires'
expandDo = require './expand_do'
Expression = require 'bundle_categories/expression'
require 'debug-folly'
debug = global.debug "closurify"

addExposures = (ast, paths) ->
  return unless paths && paths.length

  inodes = paths.map (p) ->
    _.getInodeSync _.resolveExtensionSync path.resolve p

  seen = {}; code = ''
  for inode,i in inodes when !seen[inode]
    seen[inode] = 1
    unless varName = ast.exportNames[inode] || null
      ug.AST_Node.warn "Can't expose {path} (nothing exported)", {path: paths[i]}
    code += "window['req#{inode}'] = #{varName};"

  ast.body.push ug.parse code

  return

consolidate = (filePaths, expose, requires, externs, expression) ->
  result = buildTree filePaths, expose, requires, externs, expression
  return result unless ast = result.ast
  replaceGlobal ast
  replaceRequires ast, requires
  expandDo ast
  addExposures ast, expose
  utils.wrapASTInFunction ast
  result

getDebugCode = (ast) ->
  filePaths = ast.filePaths || []

  sourcemaps = {}
  sourcemaps[filePath] = sm for filePath in filePaths when sm = _.sourceMapSync filePath

  contents = {}
  contents[filePath] = _.readFileSync filePath for filePath in filePaths

  map = SourceMap orig: sourcemaps, root: '/', content: contents # root isn't process.cwd(), it's '/' because by now all the paths should be absolute
  stream = ug.OutputStream source_map: map, beautify: true
  ast.print stream
  code = ""+stream
  sourceMap = ""+map

  sourceMapB64 = new Buffer(sourceMap).toString('base64')
  code += "/*\n//@ sourceMappingURL=data:application/json;base64,#{sourceMapB64}\n*/"

getClosureCode = (ast, options, cb) ->
  options.closure ||= {}
  options.closure['jscomp_off'] = 'globalThis'
  options.closure['compilation_level'] ||= 'ADVANCED_OPTIMIZATIONS'
  options['closure']['jar'] ||= path.resolve __dirname, '../resources/compiler.jar'

  stream = ug.OutputStream beautify: true # beautify before closure for readable compile errors
  ast = utils.unwrapASTFunction ast
  ast.print stream
  code = ""+stream

  closure.compile code, options.closure, (err, release, stderr) ->
    console.error stderr if stderr
    cb err, (release && utils.wrapCodeInFunction(release))

getUglifyCode = (ast, options) ->
  uglifyOptions = options.uglify || {}

  uglifyOptions.unused = false # to keep unused function args

  ast.figure_out_scope()
  ast = ast.transform ug.Compressor uglifyOptions

  ast.figure_out_scope()
  ast.compute_char_frequency()

  uglifyOptions.noFunArgs = true
  ast.mangle_names uglifyOptions

  ast.print_to_string()

module.exports = closurify = (codeOrFilePaths, options, cb) ->
  if typeof options is 'function'
    [cb,options] = [options, {}]

  try
    options ||= {}
    options.closure ||= {}
    requires = options.requires && {}
    expression = new Expression expression unless (expression = options.expression) instanceof Expression
    options.closure.externs = externs = [path.resolve externs] unless Array.isArray (externs = options.closure.externs ||= [])
    mins = undefined

    debug "closurify with ",options

    {ast,mins} = consolidate codeOrFilePaths, options.expose || [], requires, externs, expression
    options.requires.push v for k,v of requires if requires

  catch _error
    cb _error

  return cb null, mins unless ast

  try

    mins.sources.push ast.filePaths... if ast.filePaths
    removeDebug ast if release = options.release

  catch _error
    cb _error

  if release and release isnt 'uglify'
    getClosureCode ast, options, (err, code) ->
      mins.push code if code
      cb err, mins

  else
    try
      code = if release then getUglifyCode(ast, options) else getDebugCode(ast, options)
      mins.push code if code
    catch _error
      return cb _error

    cb null, mins

  return
