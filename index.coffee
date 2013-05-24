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
    (next) -> async.map filePaths, resolveExtension, next
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

transformRequires = (fn) ->
  pe = null
  walker = new ug.TreeTransformer (node, descend) ->
    if node instanceof ug.AST_Assign or node instanceof ug.AST_VarDef
      [ope,pe] = [pe,node]
      descend(node, this)
      pe = ope
      node
    else if isRequire(node) and pe is walker.parent()
      fn(node)

addRequires = (auto, node, cb) ->
  readCode node.filePath, (err, code) ->
    return cb(err) if err?
    node.code = code
    ast = ug.parse code

    requiredPaths = []
    ast.transform transformRequires (reqCall) ->
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
            fn node.filePath, toplevel, cb, results
      async.auto auto, (err, results) -> next(err, toplevel)
    ], cb

yay = (filePath, toplevel, cb) ->
  console.log "Yay, now do #{filePath}"
  cb()

buildRequiresTree './foo', yay, (err, ast) ->
  console.log "all done", err, ast




