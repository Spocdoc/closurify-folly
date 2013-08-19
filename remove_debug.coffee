ug = require 'uglify-js-fork'

removeASTExpressions = (removed, fn) ->
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
            throw new Error("removeDebug algorithm bug")
          body.splice(index, 1)
        else if node.car is elem
          node = node.cdr
        else
            throw new Error("removeDebug algorithm bug")

      if body && !body.length && node.TYPE is 'Var'
        return new ug.AST_EmptyStatement

    node

removeVar = (ast, v) ->
  removed = []
  ast.transform removeASTExpressions removed, (node) ->
    if node.TYPE is 'VarDef' and node.name is v
      return true
    if node.TYPE is 'SymbolRef' and
      node.thedef?.orig?[0] is v
        return true
    false

  for r in removed
    ug.AST_Node.warn "Removed node: {text}", {text: r.print_to_string()}

  ast

unique = (sortedArr) ->
  last = v for v in sortedArr when v isnt last

module.exports = removeDebug = (ast) ->
  ast.figure_out_scope()
  removed = []

  ast = ast.transform removeASTExpressions removed, (node) ->
    if node.TYPE is 'Call'
      if (func = node.expression) instanceof ug.AST_PropAccess
        if func.expression.TYPE is 'SymbolRef' and
          (func.expression.name in ['global','window']) and
          func.expression.undeclared?() and
          (func.property.value || func.property) is 'debug'
            return true
    false

  for r in removed
    ug.AST_Node.warn "Removed node: {text}", {text: r.print_to_string()}

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

