#!/usr/bin/env coffee#--nodejs --debug-brk

ug = require 'uglify-js'
fs = require 'fs'
async = require 'async'
path = require 'path'
debugger

codeTranspilers =
  js: (filePath, cb) -> fs.readFile filePath, 'utf-8', cb
  coffee: (filePath, cb) ->
    fs.readFile filePath, 'utf-8', (err, code) ->
      return cb(err) if err?
      coffee = require 'coffee-script'
      cb null, coffee.compile code, bare: true

resolveExtension = (filePath, cb) ->
  return cb null, filePath if path.extname(filePath)
  filePaths = Object.keys(codeTranspilers).map (ext) -> "#{filePath}.#{ext}"
  async.detectSeries filePaths, fs.exists, (result) -> cb(null, result)

readCode = (filePath, cb) ->
  ext = path.extname(filePath)[1..]
  unless transpiler = codeTranspilers[ext]
    return cb new Error("no known transpiler for extension #{ext}")
  transpiler filePath, cb

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

transformASTRequires = (fn) ->
  pe = null
  walker = new ug.TreeTransformer (node, descend) ->
    if node instanceof ug.AST_Assign or node instanceof ug.AST_VarDef
      [ope,pe] = [pe,node]
      descend(node, this)
      pe = ope
      node
    else if isRequire(node) and pe is walker.parent()
      fn(node)

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
  readCode node.filePath, (err, code) ->
    return cb(err) if err?
    node.code = code
    ast = ug.parse code

    requiredPaths = []
    ast.transform transformASTRequires (reqCall) ->
      requiredPaths.push path.resolve path.dirname(node.filePath), reqCall.args[0].value

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

buildRequiresTree = (filePaths, fn, cb) ->
  auto = undefined
  filePaths = [filePaths] if typeof filePaths is 'string'

  async.waterfall [
    (next) -> computeRoots filePaths, (err, a) ->
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
  cb null, ug.parse reqNode.code,
    filename: path.relative process.cwd(), reqNode.filePath
    toplevel: toplevel

wrapFilesInFunctions = do ->
  wrapperText = "(function (){}())"
  (ast) ->
    ast.transform transformASTFiles (fileNodes) ->
      parsed = ug.parse wrapperText
      parsed.transform transformFunctions (fnNode) ->
        fnNode.body = fileNodes
        fnNode
      parsed

replaceRequires = (ast) ->
  varNames = {}
  count = 0
  defs = new ug.AST_Var
    definitions: []

  ast.transform transformASTRequires (node) ->
    requirePath = path.resolve node.start.file, node.args[0].value

    unless name = varNames[requirePath]
      name = varNames[requirePath] = "__#{++count}"
      defs.definitions.push new ug.AST_VarDef name: new ug.AST_SymbolConst name: name

    new ug.AST_SymbolRef
        start : node.start,
        end   : node.end,
        name  : name

  ast.transform new ug.TreeTransformer (node) ->
    if node.TYPE is 'Toplevel'
      node.body.unshift defs
    node

buildConsolidatedAST = (filePaths, cb) ->
  buildRequiresTree filePaths, addToTree, cb

buildConsolidatedAST './foo', (err, ast) ->
  return console.error err if err?
  wrapFilesInFunctions ast
  replaceRequires ast
  console.log ast.print_to_string()




