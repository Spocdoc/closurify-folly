ug = require 'uglify-js-fork'
utils = _ = require 'underscore-folly'

module.exports = replaceExports = (filePath, ast, inode) ->
  name = null
  inExports = false
  replaceWith = undefined
  left = null

  ast.figure_out_scope()

  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    if inExports
      return node if node is left

      if node.TYPE is 'SymbolRef'
        throw new Error "algo assumes module.export assignments are at top level scope" unless node.thedef.global
        name = node.name
        replaceWith = node
        replaceWith.closurifyExport = inode
      else if node.TYPE is 'Assign' and node.left.TYPE is 'SymbolRef'
        throw new Error "algo assume module.export ops are all =" unless node.operator is '='
        left = node.left
        node.left.thedef.closurifyModuleExportsRef = true
        descend node, this

      else
        varDef = new ug.AST_VarDef
          name: new ug.AST_SymbolConst
            name: name = utils.makeName(utils.fileToVarName(node.start.file))
          value: node

        varDef.name.closurifyExport = inode

        replaceWith = new ug.AST_Var definitions: [ varDef ]

      node
    
    else if node.TYPE is 'SimpleStatement'
      descend node, this
      if node.closurifyRemove
        return new ug.AST_EmptyStatement
      else if repl = node.closurifyReplace
        return repl
      else
        return node
    else if node.TYPE is 'Assign' and inExports = utils.isModuleExports node.left
      
      throw new Error "algo assumes module.export is assigned at most once" if replaceWith
      throw new Error "algo assume module.export ops are all =" unless node.operator is '='

      left = node.left
      descend node, this
      inExports = false

      if replaceWith.TYPE is 'SymbolRef' and walker.parent().TYPE is 'SimpleStatement'
        walker.parent().closurifyRemove = true
        return node
      else
        if replaceWith instanceof ug.AST_Statement
          throw new Error "unhandled case: replace constructs of the form `foo = module.exports = 'bar'` with `module.exports = foo = 'bar'`" unless walker.parent().TYPE is 'SimpleStatement'
          walker.parent().closurifyReplace = replaceWith
          return node
        else
          replaceWith.start = node.start
          replaceWith.end = node.end
          return replaceWith

  if name
    ast.transform new ug.TreeTransformer (node, descend) ->
      if utils.isModuleExports(node) or (node.TYPE is 'SymbolRef' and node.thedef.closurifyModuleExportsRef)
        new ug.AST_SymbolRef
            start: node.start
            end: node.end
            name: name
    name
