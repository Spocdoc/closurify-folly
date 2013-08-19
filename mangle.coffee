ug = require 'uglify-js-fork'
utils = require './utils'

module.exports = mangle = {}

changeVarNames = (ast) ->
  ast.walk new ug.TreeWalker (node, descend) ->
    if node.thedef?.closurifyName
      node.name = node.thedef.closurifyName
      node
    else if node instanceof ug.AST_VarDef and node.name.thedef?.closurifyName
      node.name = node.name.thedef.closurifyName
      node
  ast

mangle.toplevel = (ast) ->
  ast.figure_out_scope()
  ast.transform new ug.TreeTransformer (node, descend) ->
    if node.TYPE is 'Toplevel'
      node.variables?.each (v) ->
        v.closurifyName =
          new ug.AST_SymbolConst
            name: utils.makeName()
      node

  changeVarNames ast
