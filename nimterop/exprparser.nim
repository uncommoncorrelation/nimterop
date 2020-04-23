import strformat, strutils, macros, sets

import regex

import compiler/[ast, renderer]

import "."/treesitter/[api, c, cpp]

import "."/[globals, getters, comphelp, tshelp]

# This version of exprparser should be able to handle:
#
# All integers + integer like expressions (hex, octal, suffixes)
# All floating point expressions (except for C++'s hex floating point stuff)
# Strings and character literals, including C's escape characters (not sure if this is the same as C++'s escape characters or not)
# Math operators (+, -, /, *)
# Some Unary operators (-, !, ~). ++, --, and & are yet to be implemented
# Any identifiers
# C type descriptors (int, char, etc)
# Boolean values (true, false)
# Shift expressions (containing anything in this list)
# Cast expressions (containing anything in this list)
# Math expressions (containing anything in this list)
# Sizeof expressions (containing anything in this list)
# Cast expressions (containing anything in this list)
# Parentheses expressions (containing anything in this list)
# Expressions containing other expressions
#
# In addition to the above, it should also handle most type coercions, except
# for where Nim can't (such as uint + -int)

type
  ExprParseError* = object of CatchableError

template val(node: TSNode): string =
  gState.currentExpr.getNodeVal(node)

proc getExprIdent*(gState: State, identName: string, kind = nskConst, parent = ""): PNode =
  ## Gets a cPlugin transformed identifier from `identName`
  ##
  ## Returns PNode(nkNone) if the identifier is blank
  result = newNode(nkNone)
  var ident = identName
  if ident != "_":
    # Process the identifier through cPlugin
    ident = gState.getIdentifier(ident, kind, parent)
  if kind == nskType:
    result = gState.getIdent(ident)
  elif ident.nBl and ident in gState.constIdentifiers:
    if gState.currentTyCastName.nBl:
      ident = ident & "." & gState.currentTyCastName
    result = gState.getIdent(ident)

proc getExprIdent*(gState: State, node: TSNode, kind = nskConst, parent = ""): PNode =
  ## Gets a cPlugin transformed identifier from `identName`
  ##
  ## Returns PNode(nkNone) if the identifier is blank
  gState.getExprIdent(node.val, kind, parent)

proc parseChar(charStr: string): uint8 {.inline.} =
  ## Parses a character literal out of a string. This is needed
  ## because treesitter gives unescaped characters when parsing
  ## strings.
  if charStr.len == 1:
    return charStr[0].uint8

  # Handle octal, hex, unicode?
  if charStr.startsWith("\\x"):
    result = parseHexInt(charStr.replace("\\x", "0x")).uint8
  elif charStr.len == 4: # Octal
    result = parseOctInt("0o" & charStr[1 ..< charStr.len]).uint8

  if result == 0:
    case charStr
    of "\\0":
      result = ord('\0')
    of "\\a":
      result = 0x07
    of "\\b":
      result = 0x08
    of "\\e":
      result = 0x1B
    of "\\f":
      result = 0x0C
    of "\\n":
      result = '\n'.uint8
    of "\\r":
      result = 0x0D
    of "\\t":
      result = 0x09
    of "\\v":
      result = 0x0B
    of "\\\\":
      result = 0x5C
    of "\\'":
      result = '\''.uint8
    of "\\\"":
      result = '\"'.uint8
    of "\\?":
      result = 0x3F
    else:
      discard

  if result > uint8.high:
    result = uint8.high

proc getCharLit(charStr: string): PNode {.inline.} =
  ## Convert a character string into a proper Nim char lit node
  result = newNode(nkCharLit)
  result.intVal = parseChar(charStr).int64

proc getFloatNode(number, suffix: string): PNode {.inline.} =
  ## Get a Nim float node from a C float expression + suffix
  let floatSuffix = number[number.len-1]
  try:
    case floatSuffix
    of 'l', 'L':
      # TODO: handle long double (128 bits)
      # result = newNode(nkFloat128Lit)
      result = newFloatNode(nkFloat64Lit, parseFloat(number[0 ..< number.len - 1]))
    of 'f', 'F':
      result = newFloatNode(nkFloat64Lit, parseFloat(number[0 ..< number.len - 1]))
    else:
      result = newFloatNode(nkFloatLit, parseFloat(number))
  except ValueError:
    raise newException(ExprParseError, &"Could not parse float value \"{number}\".")

proc getIntNode(number, suffix: string): PNode {.inline.} =
  ## Get a Nim int node from a C integer expression + suffix
  case suffix
  of "u", "U":
    result = newNode(nkUintLit)
  of "l", "L":
    result = newNode(nkInt32Lit)
  of "ul", "UL":
    result = newNode(nkUint32Lit)
  of "ll", "LL":
    result = newNode(nkInt64Lit)
  of "ull", "ULL":
    result = newNode(nkUint64Lit)
  else:
    result = newNode(nkIntLit)

  # I realize these regex are wasteful on performance, but
  # couldn't come up with a better idea.
  if number.contains(re"0[xX]"):
    result.intVal = parseHexInt(number)
    result.flags = {nfBase16}
  elif number.contains(re"0[bB]"):
    result.intVal = parseBinInt(number)
    result.flags = {nfBase2}
  elif number.contains(re"0[oO]"):
    result.intVal = parseOctInt(number)
    result.flags = {nfBase8}
  else:
    result.intVal = parseInt(number)

proc getNumNode(number, suffix: string): PNode {.inline.} =
  ## Convert a C number to a Nim number PNode
  if number.contains("."):
    getFloatNode(number, suffix)
  else:
    getIntNode(number, suffix)

proc processNumberLiteral(gState: State, node: TSNode): PNode =
  ## Parse a number literal from a TSNode. Can be a float, hex, long, etc
  result = newNode(nkNone)
  let nodeVal = node.val

  var match: RegexMatch
  const reg = re"(\-)?(0\d+|0[xX][0-9a-fA-F]+|0[bB][01]+|\d+\.\d*[fFlL]?|\d*\.\d+[fFlL]?|\d+)([ulUL]*)"
  let found = nodeVal.find(reg, match)
  if found:
    let
      prefix = if match.group(0).len > 0: nodeVal[match.group(0)[0]] else: ""
      number = nodeVal[match.group(1)[0]]
      suffix = nodeVal[match.group(2)[0]]

    result = getNumNode(number, suffix)

    if result.kind != nkNone and prefix == "-":
      result = nkPrefix.newTree(
        gState.getIdent("-"),
        result
      )
  else:
    raise newException(ExprParseError, &"Could not find a number in number_literal: \"{nodeVal}\"")

proc processCharacterLiteral(gState: State, node: TSNode): PNode =
  let val = node.val
  result = getCharLit(val[1 ..< val.len - 1])

proc processStringLiteral(gState: State, node: TSNode): PNode =
  let
    nodeVal = node.val
    strVal = nodeVal[1 ..< nodeVal.len - 1]

  const
    str = "(\\\\x[[:xdigit:]]{2}|\\\\\\d{3}|\\\\0|\\\\a|\\\\b|\\\\e|\\\\f|\\\\n|\\\\r|\\\\t|\\\\v|\\\\\\\\|\\\\'|\\\\\"|[[:ascii:]])"
    reg = re(str)

  # Convert the c string escape sequences/etc to Nim chars
  var nimStr = newStringOfCap(nodeVal.len)
  for m in strVal.findAll(reg):
    nimStr.add(parseChar(strVal[m.group(0)[0]]).chr)

  result = newStrNode(nkStrLit, nimStr)

proc processTSNode(gState: State, node: TSNode, typeofNode: var PNode): PNode

proc processShiftExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  result = newNode(nkInfix)
  let
    left = node[0]
    right = node[1]

  let shiftSym = node.tsNodeChild(1).val.strip()

  case shiftSym
  of "<<":
    result.add gState.getIdent("shl")
  of ">>":
    result.add gState.getIdent("shr")
  else:
    raise newException(ExprParseError, &"Unsupported shift symbol \"{shiftSym}\"")

  let leftNode = gState.processTSNode(left, typeofNode)

  # If the typeofNode is nil, set it
  # to be the leftNode because C's type coercion
  # happens left to right, and we want to emulate it
  if typeofNode.isNil:
    typeofNode = nkCall.newTree(
      gState.getIdent("typeof"),
      leftNode
    )

  let rightNode = gState.processTSNode(right, typeofNode)

  result.add leftNode
  result.add nkCall.newTree(
    typeofNode,
    rightNode
  )

proc processParenthesizedExpr(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  result = newNode(nkPar)
  for i in 0 ..< node.len():
    result.add(gState.processTSNode(node[i], typeofNode))

proc processCastExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  result = nkCast.newTree(
    gState.processTSNode(node[0], typeofNode),
    gState.processTSNode(node[1], typeofNode)
  )

proc getNimUnarySym(csymbol: string): string =
  ## Get the Nim equivalent of a unary C symbol
  ##
  ## TODO: Add ++, --,
  case csymbol
  of "+", "-":
    result = csymbol
  of "~", "!":
    result = "not"
  else:
    raise newException(ExprParseError, &"Unsupported unary symbol \"{csymbol}\"")

proc getNimBinarySym(csymbol: string): string =
  case csymbol
  of "|", "||":
    result = "or"
  of "&", "&&":
    result = "and"
  of "^":
    result = "xor"
  of "==", "!=",
     "+", "-", "/", "*",
     ">", "<", ">=", "<=":
    result = csymbol
  of "%":
    result = "mod"
  else:
    raise newException(ExprParseError, &"Unsupported binary symbol \"{csymbol}\"")

proc processBinaryExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  # Node has left and right children ie: (2 + 7)
  result = newNode(nkInfix)

  let
    left = node[0]
    right = node[1]
    binarySym = node.tsNodeChild(1).val.strip()
    nimSym = getNimBinarySym(binarySym)

  result.add gState.getIdent(nimSym)
  let leftNode = gState.processTSNode(left, typeofNode)

  if typeofNode.isNil:
    typeofNode = nkCall.newTree(
      gState.getIdent("typeof"),
      leftNode
    )

  let rightNode = gState.processTSNode(right, typeofNode)

  result.add leftNode
  result.add nkCall.newTree(
    typeofNode,
    rightNode
  )

proc processUnaryExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  result = newNode(nkPar)

  let
    child = node[0]
    unarySym = node.tsNodeChild(0).val.strip()
    nimSym = getNimUnarySym(unarySym)

  if nimSym == "-":
    # Special case. The minus symbol must be in front of an integer,
    # so we have to make a gentle cast here to coerce it to one.
    # Might be bad because we are overwriting the type
    # There's probably a better way of doing this
    if typeofNode.isNil:
      typeofNode = gState.getIdent("int64")

    result.add nkPrefix.newTree(
      gState.getIdent(unarySym),
      nkPar.newTree(
        nkCall.newTree(
          gState.getIdent("int64"),
          gState.processTSNode(child, typeofNode)
        )
      )
    )
  else:
    result.add nkPrefix.newTree(
      gState.getIdent(nimSym),
      gState.processTSNode(child, typeofNode)
    )

proc processUnaryOrBinaryExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  if node.len > 1:
    # Node has left and right children ie: (2 + 7)

    # Make sure the statement is of the same type as the left
    # hand argument, since some expressions return a differing
    # type than the input types (2/3 == float)
    let binExpr = processBinaryExpression(gState, node, typeofNode)
    # Note that this temp var binExpr is needed for some reason, or else we get a segfault
    result = nkCall.newTree(
      typeofNode,
      binexpr
    )

  elif node.len() == 1:
    # Node has only one child, ie -(20 + 7)
    result = processUnaryExpression(gState, node, typeofNode)
  else:
    raise newException(ExprParseError, &"Invalid {node.getName()} \"{node.val}\"")

proc processSizeofExpression(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  result = nkCall.newTree(
    gState.getIdent("sizeof"),
    gState.processTSNode(node[0], typeofNode)
  )

proc processTSNode(gState: State, node: TSNode, typeofNode: var PNode): PNode =
  ## Handle all of the types of expressions here. This proc gets called recursively
  ## in the processX procs and will drill down to sub nodes.
  result = newNode(nkNone)
  let nodeName = node.getName()

  decho "NODE: ", nodeName, ", VAL: ", node.val

  case nodeName
  of "number_literal":
    # Input -> 0x1234FE, 1231, 123u, 123ul, 123ull, 1.334f
    # Output -> 0x1234FE, 1231, 123'u, 123'u32, 123'u64, 1.334
    result = gState.processNumberLiteral(node)
  of "string_literal":
    # Input -> "foo\0\x42"
    # Output -> "foo\0"
    result = gState.processStringLiteral(node)
  of "char_literal":
    # Input -> 'F', '\034' // Octal, '\x5A' // Hex, '\r' // escape sequences
    # Output ->
    result = gState.processCharacterLiteral(node)
  of "expression_statement", "ERROR", "translation_unit":
    # Note that we're parsing partial expressions, so the TSNode might contain
    # an ERROR node. If that's the case, they usually contain children with
    # partial results, which will contain parsed expressions
    #
    # Input (top level statement) -> ((1 + 3 - IDENT) - (int)400.0)
    # Output -> (1 + typeof(1)(3) - typeof(1)(IDENT) - typeof(1)(cast[int](400.0))) # Type casting in case some args differ
    if node.len == 1:
      result = gState.processTSNode(node[0], typeofNode)
    elif node.len > 1:
      result = newNode(nkStmtListExpr)
      for i in 0 ..< node.len:
        result.add gState.processTSNode(node[i], typeofNode)
    else:
      raise newException(ExprParseError, &"Node type \"{nodeName}\" has no children")
  of "parenthesized_expression":
    # Input -> (IDENT - OTHERIDENT)
    # Output -> (IDENT - typeof(IDENT)(OTHERIDENT)) # Type casting in case OTHERIDENT is a slightly different type (uint vs int)
    result = gState.processParenthesizedExpr(node, typeofNode)
  of "sizeof_expression":
    # Input -> sizeof(char)
    # Output -> sizeof(cchar)
    result = gState.processSizeofExpression(node, typeofNode)
  # binary_expression from the new treesitter upgrade should work here
  # once we upgrade
  of "math_expression", "logical_expression", "relational_expression",
     "bitwise_expression", "equality_expression", "binary_expression":
    # Input -> a == b, a != b, !a, ~a, a < b, a > b, a <= b, a >= b
    # Output ->
    #   typeof(a)(a == typeof(a)(b))
    #   typeof(a)(a != typeof(a)(b))
    #   (not a)
    #   (not a)
    #   typeof(a)(a < typeof(a)(b))
    #   typeof(a)(a > typeof(a)(b))
    #   typeof(a)(a <= typeof(a)(b))
    #   typeof(a)(a >= typeof(a)(b))
    result = gState.processUnaryOrBinaryExpression(node, typeofNode)
  of "shift_expression":
    # Input -> a >> b, a << b
    # Output -> a shr typeof(a)(b), a shl typeof(a)(b)
    result = gState.processShiftExpression(node, typeofNode)
  of "cast_expression":
    # Input -> (int) a
    # Output -> cast[cint](a)
    result = gState.processCastExpression(node, typeofNode)
  # Why are these node types named true/false?
  of "true", "false":
    # Input -> true, false
    # Output -> true, false
    result = gState.parseString(node.val)
  of "type_descriptor", "sized_type_specifier":
    # Input -> int, unsigned int, long int, etc
    # Output -> cint, cuint, clong, etc
    let ty = getType(node.val)
    if ty.len > 0:
      # If ty is not empty, one of C's builtin types has been found
      result = gState.getExprIdent(ty, nskType, parent=node.getName())
    else:
      result = gState.getExprIdent(node.val, nskType, parent=node.getName())
      if result.kind == nkNone:
        raise newException(ExprParseError, &"Missing type specifier \"{node.val}\"")
  of "identifier":
    # Input -> IDENT
    # Output -> IDENT (if found in sym table, else error)
    result = gState.getExprIdent(node, parent=node.getName())
    if result.kind == nkNone:
      raise newException(ExprParseError, &"Missing identifier \"{node.val}\"")
  else:
    raise newException(ExprParseError, &"Unsupported node type \"{nodeName}\" for node \"{node.val}\"")

  decho "NODE RESULT: ", result

proc parseCExpression*(gState: State, code: string, name = ""): PNode =
  ## Convert the C string to a nim PNode tree
  gState.currentExpr = code
  gState.currentTyCastName = name

  result = newNode(nkNone)
  # This is used for keeping track of the type of the first
  # symbol used for type casting
  var tnode: PNode = nil
  try:
    withCodeAst(gState.currentExpr, gState.mode):
      result = gState.processTSNode(root, tnode)
  except ExprParseError as e:
    decho e.msg
    result = newNode(nkNone)
  except Exception as e:
    decho "UNEXPECTED EXCEPTION: ", e.msg
    result = newNode(nkNone)

  # Clear the state
  gState.currentExpr = ""
  gState.currentTyCastName = ""