utils = require 'js_ast_utils'
async = require 'async'
fs = require 'fs'
path = require 'path'
ug = require 'uglify-js-fork'
mangle = require './mangle'
replaceExports = require './replace_exports'
catRequires = require 'bundle_categories/requires'
glob = require 'glob'
require 'debug-fork'
debug = global.debug "closurify"

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

addExterns = (requiredPath, externs, cb) ->
  dir = path.dirname requiredPath
  async.waterfall [
    (next) -> async.concat ["#{dir}/externs/**/*.js","#{dir}/externs.js"], glob, next
    (filePaths, next) ->
      externs.push filePaths...
      next()
  ], cb

addToAuto = (auto, requiredPath, inode, requires, externs, expression, next1) ->
  autoIndex = minPaths = minInodes = indexPath = indexInode = autoRequired = requiredInode = undefined

  async.series [
    (next2) -> utils.getInode requiredPath, (err, r) -> requiredInode = r; next2 err

    (next2) ->
      if requires
        if auto[requiredInode] or requires[requiredInode]
          next1 err
        else
          requires[requiredInode] = requiredPath
          addExterns requiredPath, externs, next1
      else
        auto[inode].push requiredInode if inode?

        return next1 null if auto[requiredInode]

        (autoRequired = auto[requiredInode] = []).filePath = requiredPath
        addExterns requiredPath, externs, next2

    (next2) ->
      catRequires.resolveBrowser requiredPath, expression, (err, minPaths_) -> minPaths = minPaths_; indexPath = minPaths.indexPath; next2 err

    (next2) ->
      debug "#{requiredPath} becomes index #{indexPath}, min", minPaths
      if indexPath
        utils.getInode indexPath, (err, indexInode_) -> indexInode = indexInode_; next2 err
      else
        next2()

    (next2) ->
      if indexInode is requiredInode
        autoIndex = autoRequired
      else
        if indexPath
          autoRequired.dummy = indexInode
          autoRequired.push indexInode
          return next1 null if auto[indexInode]
          autoIndex = auto[indexInode] = []
          autoIndex.filePath = indexPath
        else
          autoRequired.dummy = true
          autoIndex = autoRequired

      async.mapSeries minPaths, utils.getInode, (err, minInodes_) -> minInodes = minInodes_; next2 err

    (next2) ->
      for minPath,i in minPaths
        minInode = minInodes[i]
        unless auto[minInode]
          autoMin = auto[minInode] = [requiredInode]
          autoMin.filePath = minPath
          autoMin.min = true
          autoMin.push minInodes[i-1] if i # to ensure alphabetical order

      if indexPath
        addRequires auto, indexInode, requires, externs, expression, next2
      else
        next2()

  ], next1


addRequires = (auto, inode, requires, externs, expression, cb) ->
  {filePath} = auto[inode]
  debug "checking requires for #{filePath}"

  async.waterfall [
    (next) ->
      if auto[inode].code?
        next null, auto[inode].code
      else
        utils.readCode filePath, next

    (code, next) ->
      auto[inode].code = code
      auto[inode].parsed = ast = ug.parse code, filename: path.relative process.cwd(), filePath

      requiredPaths = []

      utils.transformRequires ast, (reqCall) ->
        requiredPaths.push requiredPath = utils.resolveRequirePath reqCall
        debug "#{requiredPath} is required by #{filePath}"
        reqCall

      async.each requiredPaths, ((requiredPath, next1) -> addToAuto auto, requiredPath, inode, requires, externs, expression, next1), next

  ], cb

module.exports = buildTree = (filePaths, expose, requires, externs, expression, cb) ->
  auto = {}
  mins = []

  async.waterfall [
    (next) ->
      if !filePaths?
        next()
      else if typeof filePaths is 'string'
        auto['?'] = f = []
        f.code = filePaths
        f.filePath = './?'
        addRequires auto, '?', requires, externs, expression, next
      else
        filePaths = filePaths.map (p)->path.resolve(p)
        add = (filePath, next1) ->
          addToAuto auto, filePath, null, requires, externs, expression, next1
        async.each filePaths, async.compose(add, utils.resolveExtension), next

    (next) ->
      async.each expose, ((filePath, next1) ->
        addToAuto auto, filePath, null, requires, externs, expression, next1), next

    (next) ->
      toplevel = null
      for inode of auto
        auto[inode].push do (inode) ->
          (cb) ->
            autoNode = auto[inode]
            if autoNode.min
              utils.readCode autoNode.filePath, (err, code) ->
                mins.push code if code
                cb err
            else if autoNode.dummy?
              toplevel?.exportNames[inode] = toplevel.exportNames[autoNode.dummy]
            else
              toplevel = addToTree auto, inode, toplevel
            cb()
      async.auto auto, (err, results) -> next err, mins, toplevel

    ], cb

addToTree = (auto, inode, toplevel) ->
  filePath = path.relative process.cwd(), auto[inode].filePath
  ast = auto[inode].parsed

  ((toplevel ||= ast).filePaths ||= []).push filePath
  mangle.toplevel ast
  (toplevel.exportNames ||= {})[inode] = replaceExports ast
  utils.merge toplevel, ast
