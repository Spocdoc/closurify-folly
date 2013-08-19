ug = require 'uglify-js-fork'
fs = require 'fs'
async = require 'async'
path = require 'path'
SourceMap = require './sourcemap'
closure = compile: require './compile'
removeDebug = require './remove_debug'
buildTree = require './build_tree'
utils = require './utils'
replaceGlobal = require './replace_global'
replaceRequires = require './replace_requires'

addExposures = (ast, paths, cb) ->
  return cb null, ast unless paths && paths.length

  map = {}

  filePaths = paths.map (p) -> path.resolve p

  async.mapSeries filePaths, async.compose(getInode, resolveExtension), (err, inodes) ->
    seen = {}
    code = []
    for inode,i in inodes when !seen[inode]
      seen[inode] = 1
      unless varName = ast.exports[inode] || null
        ug.AST_Node.warn "Can't expose {path} (nothing exported)", {path: paths[i]}
      code.push "window['req#{inode}'] = #{varName};"

    ast.transform new ug.TreeTransformer (node) ->
      if node.TYPE is 'Toplevel'
        node.body.push ug.parse code.join('')
        node

    cb null, ast

  return

consolidate = (filePaths, expose, requires, cb) ->
  async.waterfall [
    (next) ->
      buildTree filePaths, expose, requires, next

    (ast, next) ->
      replaceGlobal ast
      replaceRequires ast, next

    (ast, next) -> addExposures ast, expose, next

    (ast, next) ->
      next null, utils.wrapASTInFunction(ast)

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
      code += "/*\n//# sourceMappingURL=data:application/json;base64,#{sourceMapB64}\n*/"

      next null, code

  ], cb

getClosureCode = (ast, closureOptions, cb) ->
  stream = ug.OutputStream beautify: true # beautify for compile errors
  ast.print stream
  code = ""+stream
  closure.compile code, closureOptions, (err, release, stderr) ->
    cb err, (release && utils.wrapCodeInFunction(release)), stderr

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

  requires = options.requires && {}

  async.waterfall [
    (next) ->
      consolidate codeOrFilePaths, options.expose, requires, next

    (ast, next) ->
      if requires
        options.requires.push filePath for inode, filePath of requires

      # note: the order is important because release alters the ast
      # so this has to run on ES5+ where the key order is preserved
      async.series
        debug: (done) -> getDebugCode ast, done
        release: (done) ->
          if options.release
            ast = removeDebug utils.unwrapASTFunction ast
            if options.release is 'uglify'
              options.uglify ||= {}
              getUglifyCode ast, options.uglify, done
            else
              options.closure ||= {}
              options.closure['compilation_level'] ||= 'ADVANCED_OPTIMIZATIONS'
              getClosureCode ast, options.closure, done
          else
            done null, undefined
        next
  ], callback
