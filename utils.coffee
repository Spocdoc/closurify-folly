fileMemoize = require 'file_memoize'
fs = require 'fs'
path = require 'path'
async = require 'async'
ug = require 'uglify-js-fork'

regexNonNameChars = /[^a-zA-Z0-9_]/g

transpilerBase =
  'coffee': fileMemoize (filePath, cb) ->
    utils.readFile filePath, (err, code) ->
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

varIndex = 0

module.exports = utils =

  isContainer: (node) ->
    body = node.body || node.definitions
    Array.isArray(body) || node.car

  transformFunctions: (fn) ->
    walker = new ug.TreeTransformer (node, descend) ->
      descend node, this
      if node.TYPE is 'Function' and changed = fn node
        changed
      else
        node

  isRequire: (node) ->
    if node instanceof ug.AST_Call
      if node.args[0] instanceof ug.AST_String and
        node.expression instanceof ug.AST_SymbolRef and
        node.expression.name is 'require' and
        node.expression.undeclared?()
          if node.args[1]?.value is 'server'
            return 'server'
          else
            return 'client'
    return false


  isExpandableDo: (node) ->
    node instanceof ug.AST_Call and node.expression instanceof ug.AST_Lambda and !(node.args?.length) and !(node.expression.argnames?.length)

  transformRequires: (fn) ->
    new ug.TreeTransformer (node) -> fn node if 'client' is utils.isRequire node

  makeName: (prefix) -> "#{prefix || ''}__#{++varIndex}"

  fileToVarName: (filePath) ->
    if name = path.basename filePath, path.extname filePath
      name = path.basename path.dirname filePath
      name = name.replace regexNonNameChars, ''
      newName = ''
      for word in name.split '_' when word
        newName += word.charAt(0).toUpperCase() + word.substr(1)
      newName
    else
      ''

  resolveRequirePath: (filePath, reqCall) ->
    rawPath = reqCall.args[0].value
    if rawPath[0] is '.' and rawPath[1] in ['.','/']
      path.resolve path.dirname(filePath), reqCall.args[0].value
    else
      require.resolve rawPath


  # this is intentionally done with strings rather than the AST because closure
  # will remove function wrappings
  wrapCodeInFunction: (code) ->
    "(function(){#{code}}());"

  wrapASTInFunction: do ->
    wrapperText = "(function (){}())"
    (ast) ->
      parsed = ug.parse wrapperText
      ast.transform new ug.TreeTransformer (node) ->
        body = node.body.splice 0
        parsed.transform utils.transformFunctions (fnNode) ->
          fnNode.body = body
          fnNode
        node.body.push parsed
        node
      ast

  unwrapASTFunction: (ast) ->
    body = null

    ast.transform new ug.TreeTransformer (node, descend) ->
      if node.TYPE is 'Toplevel'
        descend node, this
        node.body = body
        node
      else if node.TYPE is 'Function'
        body = node.body
        node
    ast

  getInode: async.memoize (filePath, cb) ->
    fs.stat filePath, (err, stat) ->
      return cb(err) if err?
      cb null, ""+stat.ino

  resolveExtension: async.memoize (filePath, cb) ->
    return cb null, filePath if path.extname(filePath)
    filePaths = Object.keys(codeTranspilers).map((ext) -> "#{filePath}.#{ext}")
      .concat Object.keys(codeTranspilers).map (ext) -> "#{filePath}/index.#{ext}"
    async.detectSeries filePaths, fs.exists, (result) ->
      if !result
        cb new Error("Can't resolve #{filePath}")
      else
        cb null, result

  readFile: fileMemoize (filePath, cb) -> fs.readFile filePath, 'utf-8', cb

  readCode: (filePath, cb) ->
    ext = path.extname(filePath)[1..]
    unless transpiler = codeTranspilers[ext]
      return cb new Error("no known transpiler for extension #{ext}")
    transpiler filePath, cb

  sourceMap: (filePath, cb) ->
    ext = path.extname(filePath)[1..]
    if mapFn = codeSourceMap[ext]
      mapFn filePath, cb
    else
      cb null, null

  merge: (dst, src) ->
    if dst is src
      return dst
    else if !dst?
      return src
    else if !src?
      return dst

    nodes = null

    src.transform new ug.TreeTransformer (node) ->
      if node.TYPE is 'Toplevel'
        nodes = node.body?.splice(0)
        node

    if nodes
      dst.transform new ug.TreeTransformer (node) ->
        if node.TYPE is 'Toplevel'
          (node.body ||= []).push nodes...
          node

    dst


  # removed is optional array of removed nodes
  removeASTExpressions: (removed, fn) ->
    if typeof removed is 'function'
      fn = removed
      removed = undefined

    target = undefined
    container = undefined
    toSplice = [] # vardef, assigns or simple statements to remove from body/definitions

    # "target" is the thing to remove. "container" is the thing that contains the
    # target (so it's the node that's mutated)

    maybeTarget = (node) ->
      container is walker.parent()

    walker = new ug.TreeTransformer (node, descend) ->
      doDescend = undefined

      if thisContainer = utils.isContainer node
        doDescend = true
        [prevContainer, container] = [container, node]
        [prevSplice, toSplice] = [toSplice, []]

      if thisTarget = maybeTarget node
        doDescend = true
        [prevTarget, target] = [target, node]

      if target and fn(node)
        removed.push target
        toSplice.push target
        doDescend = false

      return if doDescend is undefined

      descend node, this if doDescend

      if thisTarget
        target = prevTarget

      if thisContainer
        container = prevContainer
        [thisSplice, toSplice] = [toSplice, prevSplice]
        body = (node.body || node.definitions)

        for elem in thisSplice # TODO slow O(n^2) operation
          return new ug.AST_EmptyStatement if elem is node

          if body
            if !~(index = body.indexOf(elem))
              throw new Error("removeASTExpressions algorithm bug")
            body.splice(index, 1)
          else if node.car is elem
            node = node.cdr
          else
              throw new Error("removeASTExpressions algorithm bug")

        if body && !body.length && node.TYPE is 'Var'
          return new ug.AST_EmptyStatement

      node

