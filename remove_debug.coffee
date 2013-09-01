ug = require 'uglify-js-fork'
utils = require 'js_ast_utils'

removeVar = (ast, v) ->
  removed = []
  ast.transform utils.removeASTExpressions removed, (node) ->
    if node.TYPE is 'VarDef' and node.name is v
      return true
    if node.TYPE is 'SymbolRef' and
      node.thedef?.orig?[0] is v
        return true
    false

  for r in removed
    ug.AST_Node.warn "Removed node: {text}", {text: r.print_to_string(debug: true)}

  ast

unique = (sortedArr) ->
  last = v for v in sortedArr when v isnt last

module.exports = removeDebug = (ast) ->
  ast.figure_out_scope()
  removed = []

  ast = ast.transform utils.removeASTExpressions removed, (node) ->
    if node.TYPE is 'Call'
      if (func = node.expression) instanceof ug.AST_PropAccess
        if func.expression.TYPE is 'SymbolRef' and
          (func.expression.name in ['global','window']) and
          func.expression.undeclared?() and
          (func.property.value || func.property) is 'debug'
            return true
    false

  for r in removed
    ug.AST_Node.warn "Removed node: {text}", {text: r.print_to_string(debug:true)}

  variables = []

  addVar = (st) ->
    if st instanceof ug.AST_Assign
      variables.push st.left.thedef.orig[0]
    else if st instanceof ug.AST_VarDef
      variables.push st.name
    else if st.body
      addVar st.body

  addVar st for st in removed
  removeVar ast, v for v in unique(variables.sort())
  ast

