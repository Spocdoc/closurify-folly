ug = require 'uglify-js-fork'
utils = require './utils'
mangle = require './mangle'

empty = {}

module.exports = (ast) ->
  cStack =
    container: null
    child: null

  fStack =
    varLeft: null
    varIsDef: null
    replDef: null

  ast.figure_out_scope()

  # because you can't apparently descend with a different method...
  checkingReturns = false
  foundReturn = false

  ast.transform walker = new ug.TreeTransformer (node, descend) ->
    if checkingReturns
      return if node is checkingReturns
      return node if node instanceof ug.AST_Lambda
      return foundReturn = node if node.TYPE is 'Return'
      return

    return ret if ret = mangle.mangleNode node

    if Array.isArray node.body
      prev = cStack
      cStack =
        container: node

      descend node, this

      if body = node.body
        for child in body.splice(0)
          node.body.push arr...  if arr = child.closurifyExpandBefore
          node.body.push child unless child.closurifyRemove

      cStack = prev
      return node

    if walker.parent() is cStack.container
      cStack.child = node

    if cStack.child

      if utils.isExpandableDo node
        return node unless len = (body = node.expression.body)?.length
        return unless (returnNode = body[len-1]).TYPE is 'Return'

        checkingReturns = node.expression
        foundReturn = false

        descend node, this

        checkingReturns = false
        return if foundReturn isnt returnNode
        return unless fStack.varLeft and returnNode.value instanceof ug.AST_SymbolRef and returnNode.value.thedef.scope is node.expression

        fStack.replDef = returnNode.value.thedef

        node.expression.variables?.each (v) ->
          v.closurifyName =
            new ug.AST_SymbolConst
              name: if v is fStack.replDef and fStack.varLeft then fStack.varLeft else utils.makeName()

        body.splice len-1, 1
        descend node, this

        (cStack.child.closurifyExpandBefore ||= []).push body.splice(0)...
        return node

      else if node.TYPE is 'Var'
        descend node, this

        if defs = node.definitions
          for elem in defs.splice(0)
            node.definitions.push elem unless elem.closurifyRemove

        if node.definitions?.length
          return node
        else if node is cStack.child
          cStack.child.closurifyRemove = true
          return node
        else
          return new ug.AST_EmptyStatement

      else if node.TYPE is 'VarDef' and utils.isExpandableDo node.value
        prev = fStack
        fStack =
          varLeft: node.name.name
          varIsDef: true
        descend node, this
        fStack = prev

        node.closurifyRemove = true
        return node

        # remove vardef by adding unused var -- simpler
        return new ug.AST_VarDef
          name: new ug.AST_SymbolConst
            name: utils.makeName()

      # this is problematic -- there can't be a simple substitution of the created variable name (since it would be created twice).
      # TODO
      # else if node.TYPE is 'Assign' and node.left instanceof ug.AST_SymbolRef and node.operator is '=' and utils.isExpandableDo node.right
      #   throw new Error "unhandled case with assign to expandable do" unless cStack.child in [node,walker.parent()]
      #   prev = fStack
      #   fStack =
      #     varLeft: node.left.name
      #   descend node, this
      #   fStack = prev
      #   cStack.child.closurifyRemove = true
      #   return node


    unless node.TYPE in ['Var','SimpleStatement']
      prev = cStack
      cStack = empty
      descend node, this
      cStack = prev
      node

