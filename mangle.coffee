ug = require 'uglify-js-fork'
utils = require 'js_ast_utils'

module.exports = mangle = {}

mangle.mangleNode = (node) ->
  if node.thedef?.closurifyName
    node.debugName = node.name
    node.name = node.thedef.closurifyName.name
    delete node.thedef
    node
  else if node instanceof ug.AST_VarDef and node.name.thedef?.closurifyName
    {name, start, end} = node.name
    newName = node.name = node.name.thedef.closurifyName.clone()
    newName.debugName = name
    newName.start = start
    newName.end = end
    return # because the RHS could have other symbols to mangle

changeVarNames = (ast) ->
  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    ret if ret = mangle.mangleNode node
  ast

mangle.toplevel = (ast) ->
  ast.figure_out_scope()

  ast.walk new ug.TreeWalker (node, descend) ->
    if node.TYPE is 'Toplevel'
      node.variables?.each (v) ->
        v.closurifyName =
          new ug.AST_SymbolConst
            name: utils.makeName(v.name)
      node

  changeVarNames ast
