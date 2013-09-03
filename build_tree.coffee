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

addRequires = (auto, inode, requires, externs, expression, cb) ->
  {filePath} = auto[inode]
  debug "checking requires for #{filePath}"

  next = (err, code) ->
    return cb(err) if err?

    auto[inode].code = code
    auto[inode].parsed = ast = ug.parse code, filename: path.relative process.cwd(), filePath

    requiredPaths = []

    utils.transformRequires ast, (reqCall) ->
      requiredPaths.push requiredPath = utils.resolveRequirePath reqCall
      debug "#{requiredPath} is required by #{filePath}"
      reqCall

    addToAuto = (requiredPath, next1) ->
      requiredInode = undefined

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
            auto[inode].push requiredInode
            return next1 null if auto[requiredInode]
            (auto[requiredInode] = []).filePath = requiredPath
            addExterns requiredPath, externs, next2

        (next2) ->
            autoRequired = auto[requiredInode]
            autoIndex = minPaths = indexPath = indexInode = undefined
            async.waterfall [
              (next3) -> catRequires.resolveBrowser requiredPath, expression, next3

              (mins, next3) ->
                minPaths = mins
                indexPath = mins.indexPath
                utils.getInode indexPath, next3

              (indexInode_, next3) ->
                indexInode = indexInode_
                if indexInode is requiredInode
                  autoIndex = autoRequired
                else
                  autoRequired.dummy = true
                  autoRequired.push indexInode
                  return next2 null if auto[indexInode]
                  autoIndex = auto[indexInode] = []
                  autoIndex.filePath = indexPath

                async.mapSeries minPaths, utils.getInode, next3

              (minInodes, next3) ->
                for minPath,i in minPaths
                  minInode = minInodes[i]
                  autoIndex.push minInode
                  unless auto[minInode]
                    autoMin = auto[minInode] = []
                    autoMin.filePath = minPath
                    autoMin.min = true

                if indexPath
                  addRequires auto, indexInode, requires, externs, expression, next3
                else
                  next3()

            ], next2
      ], next1

    async.each requiredPaths, addToAuto, cb
    return

  if auto[inode].code?
    next null, auto[inode].code
  else
    utils.readCode filePath, next

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
      async.each roots, ((inode, cb) -> addRequires auto, inode, requires, externs, expression, cb), next

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
            else unless autoNode.dummy
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
