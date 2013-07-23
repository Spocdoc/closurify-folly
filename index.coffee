ug = require 'uglify-js'
fs = require 'fs'
async = require 'async'
path = require 'path'
SourceMap = require './sourcemap'
closure = require 'closure-compiler'
fileMemoize = require './file_memoize'
removeDebug = require './remove_debug'

readFile = fileMemoize (filePath, cb) -> fs.readFile filePath, 'utf-8', cb

transpilerBase =
  'coffee': fileMemoize (filePath, cb) ->
    readFile filePath, (err, code) ->
      return cb(err) if err?
      coffee = require 'coffee-script'
      try
        obj = coffee.compile code,
          bare: true
          sourceMap: true
          sourceFiles: [filePath]
          generatedFile: [filePath]
        cb null,
          js: obj['js']
          sourceMap: JSON.parse obj['v3SourceMap']
      catch e
        cb(new Error("Error compiling #{filePath}: #{e}"))


codeTranspilers =
  'js': (filePath, cb) -> fs.readFile filePath, 'utf-8', cb
  'coffee': (filePath, cb) ->
    transpilerBase['coffee'] filePath, (err, obj) -> cb err, obj?.js

codeSourceMap =
  'coffee': (filePath, cb) ->
    transpilerBase['coffee'] filePath, (err, obj) -> cb err, obj?.sourceMap

resolveExtension = async.memoize (filePath, cb) ->
  return cb null, filePath if path.extname(filePath)
  filePaths = Object.keys(codeTranspilers).map((ext) -> "#{filePath}.#{ext}")
    .concat Object.keys(codeTranspilers).map (ext) -> "#{filePath}/index.#{ext}"
  async.detectSeries filePaths, fs.exists, (result) ->
    if !result
      cb new Error("Can't resolve #{filePath}")
    else
      cb null, result

readCode = (filePath, cb) ->
  ext = path.extname(filePath)[1..]
  unless transpiler = codeTranspilers[ext]
    return cb new Error("no known transpiler for extension #{ext}")
  transpiler filePath, cb

getOptionalSourceMap = (filePath, cb) ->
  ext = path.extname(filePath)[1..]
  if mapFn = codeSourceMap[ext]
    mapFn filePath, cb
  else
    cb null, null

getInode = async.memoize (filePath, cb) ->
  fs.stat filePath, (err, stat) ->
    return cb(err) if err?
    cb null, ""+stat.ino

computeRoots = (filePaths, cb) ->
  async.waterfall [
    (next) -> async.map filePaths.map((p)->path.resolve(p)), resolveExtension, next
    (filePaths, next) ->
      async.mapSeries filePaths, getInode, (err, inodes) ->
        return cb(err) if err?

        auto = {}
        for inode,i in inodes
          auto[inode] = f = []
          f.filePath = filePaths[i]

        next null, auto
    ], cb

isRequire = (node) ->
  if node instanceof ug.AST_Call
    if node.args.length is 1 and
      node.args[0] instanceof ug.AST_String and
      node.expression instanceof ug.AST_Symbol and
      node.expression.name is 'require'
        return true
  return false

getRequirePath = (filePath, reqCall) ->
  rawPath = reqCall.args[0].value
  if rawPath[0] is '.' and rawPath[1] in ['.','/']
    path.resolve path.dirname(filePath), reqCall.args[0].value
  else
    require.resolve rawPath

transformASTRequires = (fn) ->
  new ug.TreeTransformer (node) -> fn node if isRequire node

transformASTGlobal = (fn) ->
  new ug.TreeTransformer (node) ->
    if node.TYPE is 'SymbolRef' and node.name is 'global' and node.undeclared?()
      fn node

transformASTExports = (fn) ->
  pe = null
  walker = new ug.TreeTransformer (node) ->
    if node instanceof ug.AST_PropAccess
      if node.expression.TYPE is 'SymbolRef' and
        node.expression.undeclared?() and
        node.expression.name is 'module' and
        (node.property.value || node.property) is 'exports'
          fn node

transformASTFiles = (fn) ->
  pf = null
  fileToNodes = {}

  walker = new ug.TreeTransformer (node, descend) ->
    if node.TYPE is 'Toplevel'
      descend node, this
      node.body.splice(0)
      
      for filePath, fileNodes of fileToNodes
        if replNode = fn fileNodes, node
          node.body.push replNode

      node
    else
      (fileToNodes[node.start.file] ||= []).push node
      node

transformFunctions = (fn) ->
  walker = new ug.TreeTransformer (node, descend) ->
    descend node, this
    if node.TYPE is 'Function' and changed = fn node
      changed
    else
      node

addRequires = (auto, node, cb) ->
  next = (err, code) ->
    return cb(err) if err?
    node.code = code
    ast = ug.parse code

    requiredPaths = []
    ast.transform transformASTRequires (reqCall) ->
      requiredPaths.push getRequirePath(node.filePath, reqCall)
      reqCall

    fn = (requiredPath, cb) ->
      getInode requiredPath, (err, inode) ->
        return cb(err) if err?
        node.push inode
        unless auto[inode]
          auto[inode] = f = []
          f.filePath = requiredPath
          addRequires auto, f, cb
        else
          cb err

    async.each requiredPaths, async.compose(fn, resolveExtension), cb
    return

  if node.code?
    next null, node.code
  else
    readCode node.filePath, next

buildRequiresTree = (filePaths, fn, cb) ->
  auto = undefined

  async.waterfall [
    (next) ->
      if typeof filePaths is 'string'
        auto = {}
        auto['?'] = f = []
        f.code = filePaths
        f.filePath = './?'
        next()
      else
        computeRoots filePaths, (err, a) ->
          auto = a
          next(err)
    (next) ->
      roots = Object.keys(auto)
      async.each roots, ((inode, cb) -> addRequires auto, auto[inode], cb), next
    (next) ->
      toplevel = null
      for inode,node of auto
        node.push do (node) ->
          (cb, results) ->
            fn node, toplevel, (err, newToplevel) ->
              toplevel = newToplevel
              cb(err)
      async.auto auto, (err, results) -> next(err, toplevel)
    ], cb

addToTree = (reqNode, toplevel, cb) ->
  filename = path.relative process.cwd(), reqNode.filePath

  toplevel = ug.parse reqNode.code,
    filename: filename
    toplevel: toplevel

  (toplevel.filenames ||= {})[filename] = true

  cb null, toplevel

wrapFilesInFunctions = do ->
  wrapperText = "(function (){}())"
  (ast, cb) ->
    ast.transform transformASTFiles (fileNodes) ->
      parsed = ug.parse wrapperText
      parsed.transform transformFunctions (fnNode) ->
        fnNode.body = fileNodes
        fnNode
      parsed
    cb?()

# this is intentionally done with strings rather than the AST because closure
# will remove function wrappings
wrapCodeInFunction = (code) ->
  "(function(){#{code}}());"

wrapASTInFunction = do ->
  wrapperText = "(function (){}())"
  (ast) ->
    parsed = ug.parse wrapperText
    ast.transform new ug.TreeTransformer (node) ->
      body = node.body.splice 0
      parsed.transform transformFunctions (fnNode) ->
        fnNode.body = body
        fnNode
      node.body.push parsed
      node
    ast

addExposures = (ast, exposures, cb) ->
  return cb null unless exposures

  map = {}

  resolve = (reqName, cb) ->
    resolveExtension path.resolve(exposures[reqName]), (err, result) ->
      return cb(err) if err?
      exposures[reqName] = result
      cb null

  async.each Object.keys(exposures), resolve, (err) ->
    return cb(err) if err?

    for reqName, filePath of exposures
      filename = path.relative process.cwd(), filePath
      return cb new Error("Can't expose: #{filePath} had no exports") unless varName = ast.filenames[filename]
      map[reqName] = varName

    code = """
      window['require'] = (function () {
        var map = {#{
          "\"#{reqName}\":#{varName}" for reqName, varName of map
        }};
        return function (name) { return map[name]; }
      })();
      """

    ast.transform new ug.TreeTransformer (node) ->
      if node.TYPE is 'Toplevel'
        node.body.push ug.parse code
        node

    cb null

  return

replaceRequires = (ast, cb) ->
  paths = []
  inodes = {}
  varNames = {}
  count = 0
  defs = new ug.AST_Var
    definitions: []

  async.waterfall [
    (next) ->
      ast.figure_out_scope()
      ast.transform transformASTExports (node) ->
        node.pathIndex = -1 + paths.push node.start.file
        node

      async.mapSeries paths, getInode, next

    (inodes, next) ->
      ast.figure_out_scope()
      ast.transform transformASTExports (node) ->
        inode = inodes[node.pathIndex]

        unless name = varNames[inode]
          name = varNames[inode] = "__#{++count}"
          defs.definitions.push new ug.AST_VarDef
            name: new ug.AST_SymbolConst
              name: name
            # value: new ug.AST_Object properties: [] # this causes trouble in closure...
          ast.filenames[node.start.file] = name

        new ug.AST_SymbolRef
            start : node.start,
            end   : node.end,
            name  : name

      paths = []
      ast.transform transformASTRequires (node) ->
        node.pathIndex = -1 + paths.push getRequirePath(node.start.file, node)
        node

      async.mapSeries paths, async.compose(getInode,resolveExtension), next

    (inodes, next) ->
      ast.transform transformASTRequires (node) ->
        inode = inodes[node.pathIndex]
        unless name = varNames[inode]
          ug.AST_Node.warn "Removed require node (nothing exported): #{node.print_to_string()}"
          return new ug.AST_EmptyStatement
        else
          new ug.AST_SymbolRef
              start : node.start,
              end   : node.end,
              name  : name

      # add variable declarations
      ast.transform new ug.TreeTransformer (node) ->
        if node.TYPE is 'Toplevel'
          node.body.unshift defs
          node
      ast.figure_out_scope()
      next()

  ], cb

  return

buildConsolidatedAST = (filePaths, cb) ->
  async.waterfall [
    (next) -> buildRequiresTree filePaths, addToTree, next
    (ast, next) ->
      ast.figure_out_scope()
      ast = ast.transform transformASTGlobal (node) ->
        new ug.AST_SymbolRef
            start : node.start,
            end   : node.end,
            name  : 'window'
      next null, ast
  ], cb

consolidate = (filePaths, expose, cb) ->
  ast = undefined

  async.waterfall [
    (next) ->
      buildConsolidatedAST filePaths, (err, a) ->
        ast = a
        next err
    (next) -> wrapFilesInFunctions ast, next
    (next) -> replaceRequires ast, next
    (next) -> addExposures ast, expose, next
    (next) ->
      next null, wrapASTInFunction(ast)
  ], cb

getDebugCode = (ast, cb) ->
  async.waterfall [
    (next) ->
      filenames = []
      for name in Object.keys(ast.filenames) when name isnt '?'
        filenames.push name

      async.parallel
        sourcemaps: (next) ->
          async.mapSeries filenames, getOptionalSourceMap, (err, result) ->
            return next(err) if err?
            sourcemaps = {}
            sourcemaps[filenames[i]] = sm for sm,i in result when sm
            next null, sourcemaps

        content: (next) ->
          async.mapSeries filenames, readFile, (err, result) ->
            return next(err) if err?
            contents = {}
            contents[filenames[i]] = code for code,i in result when code?
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
    cb err, (release && wrapCodeInFunction(release)), stderr

getUglifyCode = (ast, uglifyOptions, cb) ->
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

  async.waterfall [
    (next) ->
      consolidate codeOrFilePaths, options.expose, next
    (ast, next) ->
      # note: the order is important because release alters the ast
      # so this has to run on ES5+ where the key order is preserved
      async.series
        debug: (done) -> getDebugCode ast, done
        release: (done) ->
          if options.release
            ast = removeDebug ast
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
