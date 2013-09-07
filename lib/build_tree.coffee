_ = require 'lodash-fork'
utils = require 'js_ast_utils'
async = require 'async'
fs = require 'fs'
path = require 'path'
ug = require 'uglify-js-fork'
replaceExports = require './replace_exports'
catRequires = require 'bundle_categories/requires'
glob = require 'glob'
resolve = require 'resolve-fork'
require 'debug-fork'
debug = global.debug "closurify"

addExterns = (requiredPath, externs) ->
  dir = path.dirname requiredPath
  filePaths = glob.sync("#{dir}/externs/**/*.js").concat glob.sync "#{dir}/externs.js"
  externs.push filePaths...
  return

addToAuto = (auto, requiredPath, inode, requires, externs, expression) ->
  requiredInode = _.getInodeSync requiredPath

  if requires and inode?
    unless auto[requiredInode] or requires[requiredInode]
      requires[requiredInode] = requiredPath
      addExterns requiredPath, externs
    return

  auto[inode].push requiredInode if inode?
  return if auto[requiredInode]

  (autoRequired = auto[requiredInode] = []).filePath = requiredPath
  addExterns requiredPath, externs

  minPaths = catRequires.resolveBrowser path.resolve(requiredPath), expression
  indexPath = minPaths.indexPath
  indexInode = if indexPath then _.getInodeSync indexPath else undefined

  debug "#{requiredPath} becomes index #{indexPath}, min", minPaths

  if indexInode is requiredInode
    autoIndex = autoRequired
  else if indexPath
    autoRequired.dummy = indexInode
    autoRequired.push indexInode
    return if auto[indexInode]
    autoIndex = auto[indexInode] = []
    autoIndex.filePath = indexPath
  else
    autoRequired.dummy = true
    autoIndex = autoRequired

  for minPath,i in minPaths
    minInode = _.getInodeSync minPath
    unless auto[minInode]
      autoMin = auto[minInode] = [requiredInode]
      autoMin.filePath = minPath
      autoMin.min = true
      autoMin.push lastInode if i # to ensure alphabetical order
    lastInode = minInode

  if indexInode?
    addRequires auto, indexInode, requires, externs, expression
  return

addRequires = (auto, inode, requires, externs, expression) ->
  {filePath} = auto[inode]
  debug "checking requires for #{filePath || '[passed code]'}"

  if filePath
    code = auto[inode].code ||= _.readCodeSync filePath
    auto[inode].parsed = ast = utils.deepClone utils.getMangledAst filePath, code
    requiredPaths = utils.getRequiresSync filePath
  else
    requiredPaths = utils.getAstRequiresSync auto[inode].parsed

  debug "#{filePath || '[passed code]'} requires ",requiredPaths

  for requiredPath in requiredPaths
    addToAuto auto, requiredPath, inode, requires, externs, expression

  return

addToTree = (autoNode, inode, toplevel) ->
  ast = autoNode.parsed

  filePaths = (toplevel ||= ast).filePaths ||= []
  exportNames = toplevel.exportNames ||= {}

  unless inode is '?'
    filePath = autoNode.filePath
    filePaths.push filePath
    exportNames[inode] = replaceExports(filePath, ast, inode)
  utils.merge toplevel, ast

  toplevel

module.exports = buildTree = (filePaths, expose, requires, externs, expression) ->
  auto = {}
  result =
    mins: []
    ast: null
  result.mins.files = []

  if typeof filePaths is 'string'
    auto['?'] = f = []
    f.code = filePaths
    f.parsed = ug.parse filePaths, filename: './?'
    addRequires auto, '?', requires, externs, expression
    filePaths = expose
  else if filePaths
    filePaths = expose.concat(filePaths)
  else
    filePaths = expose

  for filePath in filePaths
    addToAuto auto, resolve(filePath), null, requires, externs, expression

  # for inode, autoNode of auto
  _.tasks auto, (inode, autoNode) ->
    if autoNode.min
      result.mins.push _.readCodeSync autoNode.filePath
      result.mins.files.push autoNode.filePath
    else if autoNode.dummy?
      result.ast?.exportNames[inode] = result.ast.exportNames[autoNode.dummy]
    else
      result.ast = addToTree autoNode, inode, result.ast
    return

  result
