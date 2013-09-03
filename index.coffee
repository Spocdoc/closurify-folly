ug = require 'uglify-js-fork'
fs = require 'fs'
async = require 'async'
path = require 'path'
SourceMap = require './sourcemap'
closure = compile: require './compile'
removeDebug = require './remove_debug'
buildTree = require './build_tree'
utils = require 'js_ast_utils'
replaceGlobal = require './replace_global'
replaceRequires = require './replace_requires'
expandDo = require './expand_do'
Expression = require 'bundle_categories/expression'

addExposures = (ast, paths, cb) ->
  return cb null, ast unless paths && paths.length

  map = {}

  filePaths = paths.map (p) -> path.resolve p

  async.mapSeries filePaths, async.compose(utils.getInode, utils.resolveExtension), (err, inodes) ->
    seen = {}
    code = []
    for inode,i in inodes when !seen[inode]
      seen[inode] = 1
      unless varName = ast.exportNames[inode] || null
        ug.AST_Node.warn "Can't expose {path} (nothing exported)", {path: paths[i]}
      code.push "window['req#{inode}'] = #{varName};"

    ast.transform new ug.TreeTransformer (node) ->
      if node.TYPE is 'Toplevel'
        node.body.push ug.parse code.join('')
        node

    cb null, ast

  return

consolidate = (filePaths, expose, requires, externs, expression, cb) ->
  mins = undefined

  async.waterfall [
    (next) ->
      buildTree filePaths, expose, requires, externs, expression, next

    (mins_, ast, next) ->
      mins = mins_

      return cb null, mins, ast unless ast

      replaceGlobal ast
      replaceRequires ast, requires, next

    (ast, next) ->
      expandDo ast

      addExposures ast, expose, next

    (ast, next) ->
      next null, mins, utils.wrapASTInFunction(ast)

  ], cb

getDebugCode = (ast, cb) ->
  async.waterfall [
    (next) ->
      filePaths = ast.filePaths
      ~(i = filePaths.indexOf '?') && filePaths.splice(i,1)

      async.parallel
        sourcemaps: (next) ->
          async.mapSeries filePaths, utils.sourceMap, (err, result) ->
            return next(err) if err?
            sourcemaps = {}
            sourcemaps[filePaths[i]] = sm for sm,i in result when sm
            next null, sourcemaps

        content: (next) ->
          async.mapSeries filePaths, utils.readFile, (err, result) ->
            return next(err) if err?
            contents = {}
            contents[filePaths[i]] = code for code,i in result when code?
            next null, contents

        (err, result) ->
          return next err if err?
          next err, result.content, result.sourcemaps

    (contents, sourcemaps, next) ->
      map = SourceMap orig: sourcemaps, root: process.cwd(), content: contents
      stream = ug.OutputStream source_map: map, beautify: true
      ast.print stream
      code = ""+stream
      sourceMap = ""+map

      sourceMapB64 = new Buffer(sourceMap).toString('base64')
      code += "/*\n//@ sourceMappingURL=data:application/json;base64,#{sourceMapB64}\n*/"

      next null, code

  ], cb

getClosureCode = (ast, closureOptions, cb) ->
  stream = ug.OutputStream beautify: true # beautify before closure for readable compile errors
  ast.print stream
  code = ""+stream
  closure.compile code, closureOptions, (err, release, stderr) ->
    console.error stderr if stderr
    cb err, (release && utils.wrapCodeInFunction(release))

getUglifyCode = (ast, uglifyOptions, cb) ->
  uglifyOptions.unused = false # to keep unused function args

  ast.figure_out_scope()
  ast = ast.transform ug.Compressor uglifyOptions

  ast.figure_out_scope()
  ast.compute_char_frequency()

  uglifyOptions.noFunArgs = true
  ast.mangle_names uglifyOptions

  stream = ug.OutputStream()

  ast.print stream
  cb null, ''+stream

module.exports = closurify = (codeOrFilePaths, options, callback) ->
  if typeof options is 'function'
    [callback,options] = [options, {}]

  options.closure ||= {}
  requires = options.requires && {}
  expression = new Expression expression unless (expression = options.expression) instanceof Expression
  externs = [path.resolve externs] unless Array.isArray (externs = options.closure.externs || [])
  mins = undefined

  async.waterfall [
    (next) ->
      consolidate codeOrFilePaths, options.expose, requires, externs, expression, next

    (mins_, ast, next) ->
      mins = mins_
      return next null, '' unless ast

      ast = removeDebug ast

      if requires
        options.requires.push filePath for inode, filePath of requires

      if options['release']
        if options.release is 'uglify'
          options.uglify ||= {}
          getUglifyCode ast, options.uglify, next
        else
          ast = utils.unwrapASTFunction ast
          options.closure['jscomp_off'] = 'globalThis'
          options.closure['compilation_level'] ||= 'ADVANCED_OPTIMIZATIONS'
          options.closure['externs'] = externs
          getClosureCode ast, options.closure, next
      else
        getDebugCode ast, next

    (code, next) ->
      mins ||= []
      mins.push code if code
      next null, mins

  ], callback
