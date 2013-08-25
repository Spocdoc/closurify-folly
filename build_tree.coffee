utils = require './utils'
async = require 'async'
fs = require 'fs'
path = require 'path'
ug = require 'uglify-js-fork'
mangle = require './mangle'
replaceExports = require './replace_exports'



addRoots = (auto, filePaths, cb) ->
  async.waterfall [
    (next) ->
      async.map filePaths.map((p)->path.resolve(p)), utils.resolveExtension, next

    (filePaths, next) ->
      async.mapSeries filePaths, utils.getInode, (err, inodes) ->
        return cb(err) if err?

        for inode,i in inodes when !auto[inode]
          auto[inode] = f = []
          f.filePath = filePaths[i]

        next null
    ], cb

addRequires = (auto, inode, requires, cb) ->
  {filePath} = auto[inode]

  next = (err, code) ->
    return cb(err) if err?

    auto[inode].code = code
    auto[inode].parsed = ast = ug.parse code, filename: path.relative process.cwd(), filePath
    ast.figure_out_scope() # to resolve global require() calls

    requiredPaths = []

    ast.transform utils.transformRequires (reqCall) ->
      requiredPaths.push utils.resolveRequirePath(filePath, reqCall)
      reqCall

    addToAuto = (requiredPath, cb) ->
      utils.getInode requiredPath, (err, requiredInode) ->
        return cb(err) if err?

        if requires
          requires[requiredInode] = requiredPath unless auto[requiredInode]
          cb err

        else
          auto[inode].push requiredInode

          unless auto[requiredInode]
            auto[requiredInode] = f = []
            f.filePath = requiredPath
            addRequires auto, requiredInode, requires, cb

          else
            cb err

    async.each requiredPaths, async.compose(addToAuto, utils.resolveExtension), cb
    return

  if auto[inode].code?
    next null, auto[inode].code
  else
    utils.readCode filePath, next

module.exports = buildTree = (filePaths, expose, requires, cb) ->
  auto = {}

  async.waterfall [
    (next) ->
      if typeof filePaths is 'string'
        auto['?'] = f = []
        f.code = filePaths
        f.filePath = './?'
        next()
      else
        addRoots auto, filePaths, next

    (next) ->
      if expose and expose.length
        addRoots auto, expose, next
      else
        next()

    (next) ->
      roots = Object.keys(auto)
      async.each roots, ((inode, cb) -> addRequires auto, inode, requires, cb), next

    (next) ->
      toplevel = null
      for inode of auto
        auto[inode].push do (inode) ->
          (cb) ->
            toplevel = addToTree auto, inode, toplevel
            cb()
      async.auto auto, (err, results) -> next(err, toplevel)
    ], cb

addToTree = (auto, inode, toplevel) ->
  filePath = path.relative process.cwd(), auto[inode].filePath
  ast = auto[inode].parsed

  ((toplevel ||= ast).filePaths ||= []).push filePath
  mangle.toplevel ast
  (toplevel.exportNames ||= {})[inode] = replaceExports ast
  utils.merge toplevel, ast
