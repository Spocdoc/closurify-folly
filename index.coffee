ug = require 'uglify-js-fork'
fs = require 'fs'
async = require 'async'
path = require 'path'
SourceMap = require './sourcemap'
closure = compile: require './compile'
removeDebug = require './remove_debug'
buildTree = require './build_tree'
utils = require 'js_ast_utils'
_ = require 'lodash-fork'
replaceGlobal = require './replace_global'
replaceRequires = require './replace_requires'
expandDo = require './expand_do'
Expression = require 'bundle_categories/expression'
require 'debug-fork'
debug = global.debug "closurify"

addExposures = (ast, paths) ->
  return unless paths && paths.length

  inodes = paths.map (p) ->
    _.getInodeSync _.resolveExtensionSync path.resolve p

  seen = {}; code = []
  for inode,i in inodes when !seen[inode]
    seen[inode] = 1
    unless varName = ast.exportNames[inode] || null
      ug.AST_Node.warn "Can't expose {path} (nothing exported)", {path: paths[i]}
    code.push "window['req#{inode}'] = #{varName};"

  ast.transform new ug.TreeTransformer (node) ->
    if node.TYPE is 'Toplevel'
      node.body.push ug.parse code.join('')
      node

  return

consolidate = (filePaths, expose, requires, externs, expression, cb) ->
  buildTree filePaths, expose, requires, externs, expression, (err, result) ->
    return cb err if err?
    return cb null, result unless ast = result.ast

    replaceGlobal ast
    replaceRequires ast, requires
    expandDo ast
    addExposures ast, expose
    utils.wrapASTInFunction ast

    cb null, result

getDebugCode = (ast) ->
  filePaths = ast.filePaths || []
  ~(i = filePaths.indexOf '?') && filePaths.splice(i,1)

  sourcemaps = {}
  sourcemaps[filePath] = sm for filePath in filePaths when sm = _.sourceMapSync filePath

  contents = {}
  contents[filePath] = _.readFileSync filePath for filePath in filePaths

  map = SourceMap orig: sourcemaps, root: process.cwd(), content: contents
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

  options ||= {}
  options.closure ||= {}
  requires = options.requires && {}
  expression = new Expression expression unless (expression = options.expression) instanceof Expression
  options.closure.externs = externs = [path.resolve externs] unless Array.isArray (externs = options.closure.externs ||= [])
  mins = undefined

  debug "closurify with ",options

  consolidate codeOrFilePaths, options.expose || [], requires, externs, expression, (err, result) ->
    options.requires.push v for k,v of requires if requires

    return cb err if err?
    {ast,mins} = result

    return cb err, mins unless ast

    removeDebug ast if release = options.release

    if release and release isnt 'uglify'
      getClosureCode ast, options, (err, code) ->
        mins.push code if code
        cb err, mins

    else
      code = if release then getUglifyCode(ast, options) else getDebugCode(ast, options)
      mins.push code if code
      cb err, mins

    return
