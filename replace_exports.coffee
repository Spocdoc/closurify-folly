ug = require 'uglify-js-fork'
utils = require './utils'

isModuleExports = (node) ->
  (node instanceof ug.AST_PropAccess) and
    node.expression.TYPE is 'SymbolRef' and
      node.expression.undeclared?() and
      node.expression.name is 'module' and
      (node.property.value || node.property) is 'exports'

module.exports = replaceExports = (ast) ->
  name = null
  inExports = false
  replaceWith = undefined
  left = null

  ast.figure_out_scope()

  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    if inExports
      return node if node is left

      if node instanceof ug.AST_SymbolRef
        throw new Error "algo assumes module.export assignments are at top level scope" unless node.thedef.global
        name = node.name
        replaceWith = node
      else if (node instanceof ug.AST_Assign) and node.left instanceof ug.AST_SymbolRef
        throw new Error "algo assume module.export ops are all =" unless node.operator is '='
        left = node.left
        node.left.thedef.closurifyModuleExportsRef = true
        descend node, this

      else
        replaceWith = new ug.AST_Var
          definitions: [
            new ug.AST_VarDef
              name: new ug.AST_SymbolConst
                name: name = utils.makeName()
              value: node
          ]

      node
    
    else if node.TYPE is 'SimpleStatement'
      descend node, this
      if node.closurifyRemove
        return new ug.AST_EmptyStatement
      else if repl = node.closurifyReplace
        return repl
      else
        return node
    else if (node instanceof ug.AST_Assign) and inExports = isModuleExports node.left
      
      throw new Error "algo assumes module.export is assigned at most once" if replaceWith
      throw new Error "algo assume module.export ops are all =" unless node.operator is '='

      left = node.left
      descend node, this
      inExports = false

      if replaceWith instanceof ug.AST_SymbolRef and walker.parent().TYPE is 'SimpleStatement'
        walker.parent().closurifyRemove = true
        return node
      else
        if replaceWith instanceof ug.AST_Statement
          throw new Error "unhandled case" unless walker.parent().TYPE is 'SimpleStatement'
          walker.parent().closurifyReplace = replaceWith
          return node
        else
          replaceWith.start = node.start
          replaceWith.end = node.end
          return replaceWith

  if name
    ast.transform new ug.TreeTransformer (node, descend) ->
      if isModuleExports(node) or (node instanceof ug.AST_SymbolRef and node.thedef.closurifyModuleExportsRef)
        new ug.AST_SymbolRef
            start: node.start
            end: node.end
            name: name
    name
