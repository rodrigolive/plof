# `nodes.coffee` contains all of the node classes for the syntax tree. Most
# nodes are created as the result of actions in the [grammar](grammar.html),
# but some are created by other nodes as a method of code generation. To convert
# the syntax tree into a string of JavaScript code, call `compile()` on the root.

{Scope} = require './scope'

# Import the helpers we plan to use.
{compact, flatten, extend, merge, del, starts, ends, last} = require './helpers'

exports.extend = extend  # for parser

# Constant functions for nodes that don't need customization.
YES     = -> yes
NO      = -> no
THIS    = -> this
NEGATE  = -> @negated = not @negated; this

#### Base

# The **Base** is the abstract base class for all nodes in the syntax tree.
# Each subclass implements the `compileNode` method, which performs the
# code generation for that node. To compile a node to JavaScript,
# call `compile` on it, which wraps `compileNode` in some generic extra smarts,
# to know when the generated code needs to be wrapped up in a closure.
# An options hash is passed and cloned throughout, containing information about
# the environment from higher in the tree (such as if a returned value is
# being requested by the surrounding function), information about the current
# scope, and indentation level.
exports.Base = class Base

  # Common logic for determining whether to wrap this node in a closure before
  # compiling it, or to compile directly. We need to wrap if this node is a
  # *statement*, and it's not a *pureStatement*, and we're not at
  # the top level of a block (which would be unnecessary), and we haven't
  # already been asked to return the result (because statements know how to
  # return results).
  compile: (o, lvl) ->
    o        = extend {}, o
    o.level  = lvl if lvl
    node     = @unfoldSoak(o) or this
    node.tab = o.indent
    if o.level is LEVEL_TOP or not node.isStatement(o)
      node.compileNode o
    else
      node.compileClosure o

  # Statements converted into expressions via closure-wrapping share a scope
  # object with their parent closure, to preserve the expected lexical scope.
  compileClosure: (o) ->
    if @jumps() or this instanceof Throw
      throw SyntaxError 'cannot use a pure statement in an expression.'
    o.sharedScope = yes
    Closure.wrap(this).compileNode o

  # If the code generation wishes to use the result of a complex expression
  # in multiple places, ensure that the expression is only ever evaluated once,
  # by assigning it to a temporary variable. Pass a level to precompile.
  cache: (o, level, reused) ->
    unless @isComplex()
      ref = if level then @compile o, level else this
      [ref, ref]
    else
      ref = new Literal reused or o.scope.freeVariable 'ref'
      sub = new Assign ref, this
      if level then [sub.compile(o, level), ref.value] else [sub, ref]

  # Compile to a source/variable pair suitable for looping.
  compileLoopReference: (o, name) ->
    src = tmp = @compile o, LEVEL_LIST
    unless -Infinity < +src < Infinity or IDENTIFIER.test(src) and o.scope.check(src, yes)
      src = "#{ tmp = o.scope.freeVariable name } = #{src}"
    [src, tmp]

  # Construct a node that returns the current node's result.
  # Note that this is overridden for smarter behavior for
  # many statement nodes (e.g. If, For)...
  makeReturn: ->
    new Return this

  # Does this node, or any of its children, contain a node of a certain kind?
  # Recursively traverses down the *children* of the nodes, yielding to a block
  # and returning true when the block finds a match. `contains` does not cross
  # scope boundaries.
  contains: (pred) ->
    contains = no
    @traverseChildren no, (node) ->
      if pred node
        contains = yes
        return no
    contains

  # Is this node of a certain type, or does it contain the type?
  containsType: (type) ->
    this instanceof type or @contains (node) -> node instanceof type

  # Pull out the last non-comment node of a node list.
  lastNonComment: (list) ->
    i = list.length
    return list[i] while i-- when list[i] not instanceof Comment
    null

  # `toString` representation of the node, for inspecting the parse tree.
  # This is what `coffee --nodes` prints out.
  toString: (idt = '', name = @constructor.name) ->
    tree = '\n' + idt + name
    tree += '?' if @soak
    @eachChild (node) -> tree += node.toString idt + TAB
    tree

  # Passes each child to a function, breaking when the function returns `false`.
  eachChild: (func) ->
    return this unless @children
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        return this if func(child) is false
    this

  traverseChildren: (crossScope, func) ->
    @eachChild (child) ->
      return false if func(child) is false
      child.traverseChildren crossScope, func

  invert: ->
    new Op '!', this

  unwrapAll: ->
    node = this
    continue until node is node = node.unwrap()
    node

  # Default implementations of the common node properties and methods. Nodes
  # will override these with custom logic, if needed.
  children: []

  isStatement     : NO
  jumps           : NO
  isComplex       : YES
  isChainable     : NO
  isAssignable    : NO

  unwrap     : THIS
  unfoldSoak : NO

  # Is this node used to assign a certain variable?
  assigns: NO

#### Block

# The block is the list of expressions that forms the body of an
# indented block of code -- the implementation of a function, a clause in an
# `if`, `switch`, or `try`, and so on...
exports.Block = class Block extends Base
  constructor: (nodes) ->
    @expressions = compact flatten nodes or []

  children: ['expressions']

  # Tack an expression on to the end of this expression list.
  push: (node) ->
    @expressions.push node
    this

  # Remove and return the last expression of this expression list.
  pop: ->
    @expressions.pop()

  # Add an expression at the beginning of this expression list.
  unshift: (node) ->
    @expressions.unshift node
    this

  # If this Block consists of just a single node, unwrap it by pulling
  # it back out.
  unwrap: ->
    if @expressions.length is 1 then @expressions[0] else this

  # Is this an empty block of code?
  isEmpty: ->
    not @expressions.length

  isStatement: (o) ->
    for exp in @expressions when exp.isStatement o
      return yes
    no

  jumps: (o) ->
    for exp in @expressions
      return exp if exp.jumps o

  # An Block node does not return its entire body, rather it
  # ensures that the final expression is returned.
  makeReturn: ->
    len = @expressions.length
    while len--
      expr = @expressions[len]
      if expr not instanceof Comment
        @expressions[len] = expr.makeReturn()
        @expressions.splice(len, 1) if expr instanceof Return and not expr.expression
        break
    this

  # An **Block** is the only node that can serve as the root.
  compile: (o = {}, level) ->
    if o.scope then super o, level else @compileRoot o

  # Compile all expressions within the **Block** body. If we need to
  # return the result, and it's an expression, simply return it. If it's a
  # statement, ask the statement to do so.
  compileNode: (o) ->
    console.log("Block")
    @tab  = o.indent
    top   = o.level is LEVEL_TOP
    codes = []
    for node in @expressions
      node = node.unwrapAll()
      node = (node.unfoldSoak(o) or node)
      if top
        node.front = true
        code = node.compile o
        codes.push if node.isStatement o then code else @tab + code + ';'
      else
        codes.push node.compile o, LEVEL_LIST
    return codes.join '\n' if top
    code = codes.join(', ') or 'void 0'
    if codes.length > 1 and o.level >= LEVEL_LIST then "(#{code})" else code

  # If we happen to be the top-level **Block**, wrap everything in
  # a safety closure, unless requested not to.
  # It would be better not to generate them in the first place, but for now,
  # clean up obvious double-parentheses.
  compileRoot: (o) ->
    o.indent = @tab = if o.bare then '' else TAB
    o.scope  = new Scope null, this, null
    o.level  = LEVEL_TOP
    code     = @compileWithDeclarations o
    if o.bare then code else
      return "use constant true => 1;\ndo {\n#{code}\n};\n"  # rr

  # Compile the expressions body for the contents of a function, with
  # declarations of all inner variables pushed up to the top.
  compileWithDeclarations: (o) ->
    code = post = ''
    for exp, i in @expressions
      exp = exp.unwrap()
      break unless exp instanceof Comment or exp instanceof Literal
    o = merge(o, level: LEVEL_TOP)
    if i
      rest = @expressions.splice i, @expressions.length
      code = @compileNode(o)
      @expressions = rest
    post = @compileNode o
    {scope} = o
    if scope.expressions is this
      declars = o.scope.hasDeclarations()
      assigns = scope.hasAssignments
      if (declars or assigns) and i
        code += '\n'
      if declars
        code += "#{@tab}my ( $#{ scope.declaredVariables().join(', $') } );\n"  # rr
      if assigns
        code += "#{@tab}my ( $#{ multident scope.assignedVariables().join(', $'), @tab };\n"
    code + post

  # Wrap up the given nodes as an **Block**, unless it already happens
  # to be one.
  @wrap: (nodes) ->
    return nodes[0] if nodes.length is 1 and nodes[0] instanceof Block
    new Block nodes

#### Literal

# Literals are static values that can be passed through directly into
# JavaScript without translation, such as: strings, numbers,
# `true`, `false`, `null`...
exports.Literal = class Literal extends Base
  constructor: (@value) ->

  makeReturn: ->
    if @isStatement() then this else new Return this

  isAssignable: ->
    IDENTIFIER.test @value

  isStatement: ->
    @value in ['last', 'next', 'debugger']

  isComplex: NO

  assigns: (name) ->
    name is @value

  jumps: (o) ->
    return no unless @isStatement()
    if not (o and (o.loop or o.block and (@value isnt 'continue'))) then this else no

  compileNode: (o) ->
    console.log("Literal")
    code = if @isUndefined
      if o.level >= LEVEL_ACCESS then '(void 0)' else 'void 0'
    else if @value.reserved
      "\"#{@value}\""
    else
      @value
    console.log ">>>>>>> #{code} + #{@isAssignable()}"
    if @isStatement() then "#{@tab}#{code};" else code

  toString: ->
    ' "' + @value + '"'

#### Return

# A `return` is a *pureStatement* -- wrapping it in a closure wouldn't
# make sense.
exports.Return = class Return extends Base
  constructor: (expr) ->
    @expression = expr if expr and not expr.unwrap().isUndefined

  children: ['expression']

  isStatement:     YES
  makeReturn:      THIS
  jumps:           THIS

  compile: (o, level) ->
    expr = @expression?.makeReturn()
    if expr and expr not instanceof Return then expr.compile o, level else super o, level

  compileNode: (o) ->
    console.log("Return")
    @tab + "return#{ if @expression then ' ' + @expression.compile(o, LEVEL_PAREN) else '' };"

#### Value

# A value, variable or literal or parenthesized, indexed or dotted into,
# or vanilla.
exports.Value = class Value extends Base
  constructor: (base, props, tag) ->
    return base if not props and base instanceof Value
    @base       = base
    @properties = props or []
    @[tag]      = true if tag
    return this

  children: ['base', 'properties']

  # Add a property access to the list.
  push: (prop) ->
    @properties.push prop
    this

  hasProperties: ->
    !!@properties.length

  # Some boolean checks for the benefit of other nodes.
  isArray        : -> not @properties.length and @base instanceof Arr
  isComplex      : -> @hasProperties() or @base.isComplex()
  isAssignable   : -> @hasProperties() or @base.isAssignable()
  isSimpleNumber : -> @base instanceof Literal and SIMPLENUM.test @base.value
  isAtomic       : ->
    for node in @properties.concat @base
      return no if node.soak or node instanceof Call
    yes

  isStatement : (o)    -> not @properties.length and @base.isStatement o
  assigns     : (name) -> not @properties.length and @base.assigns name
  jumps       : (o)    -> not @properties.length and @base.jumps o

  isObject: (onlyGenerated) ->
    return no if @properties.length
    (@base instanceof Obj) and (not onlyGenerated or @base.generated)

  isSplice: ->
    last(@properties) instanceof Slice

  makeReturn: ->
    if @properties.length then super() else @base.makeReturn()

  # The value can be unwrapped as its inner node, if there are no attached
  # properties.
  unwrap: ->
    if @properties.length then this else @base

  # A reference has base part (`this` value) and name part.
  # We cache them separately for compiling complex expressions.
  # `a()[b()] ?= c` -> `(_base = a())[_name = b()] ? _base[_name] = c`
  cacheReference: (o) ->
    name = last @properties
    if @properties.length < 2 and not @base.isComplex() and not name?.isComplex()
      return [this, this]  # `a` `a.b`
    base = new Value @base, @properties.slice 0, -1
    if base.isComplex()  # `a().b`
      bref = new Literal o.scope.freeVariable 'base'
      base = new Value new Parens new Assign bref, base
    return [base, bref] unless name  # `a()`
    if name.isComplex()  # `a[b()]`
      nref = new Literal o.scope.freeVariable 'name'
      name = new Index new Assign nref, name.index
      nref = new Index nref
    [base.push(name), new Value(bref or base.base, [nref or name])]

  # We compile a value to JavaScript by compiling and joining each property.
  # Things get much more interesting if the chain of properties has *soak*
  # operators `?.` interspersed. Then we have to take care not to accidentally
  # evaluate anything twice when building the soak chain.
  compileNode: (o) ->
    console.log("Value =" + @base.compile( o ) + ", isAssignable=" + @isAssignable() )
    @base.front = @front
    props = @properties
    code  = @base.compile o, if props.length then LEVEL_ACCESS else null
    code  = "#{code}->" if (@base instanceof Parens or props.length) and SIMPLENUM.test code  # rr
    code += prop.compile o for prop in props
    code

  # Unfold a soak into an `If`: `a?.b` -> `a.b if a?`
  unfoldSoak: (o) ->
    return @unfoldedSoak if @unfoldedSoak?
    result = do =>
      if ifn = @base.unfoldSoak o
        Array::push.apply ifn.body.properties, @properties
        return ifn
      for prop, i in @properties when prop.soak
        prop.soak = off
        fst = new Value @base, @properties.slice 0, i
        snd = new Value @base, @properties.slice i
        if fst.isComplex()
          ref = new Literal o.scope.freeVariable 'ref'
          fst = new Parens new Assign ref, fst
          snd.base = ref
        return new If new Existence(fst), snd, soak: on
      null
    @unfoldedSoak = result or no

#### Comment

# CoffeeScript passes through block comments as JavaScript block comments
# at the same position.
exports.Comment = class Comment extends Base
  constructor: (@comment) ->

  isStatement:     YES
  makeReturn:      THIS

  compileNode: (o, level) ->
    code = '/*' + multident(@comment, @tab) + '*/'
    code = o.indent + code if (level or o.level) is LEVEL_TOP
    code

#### Call

# Node for a function invocation. Takes care of converting `super()` calls into
# calls against the prototype's function of the same name.
exports.Call = class Call extends Base
  constructor: (variable, @args = [], @soak) ->
    @isNew    = false
    @isSuper  = variable is 'super'
    @variable = if @isSuper then null else variable

  children: ['variable', 'args']

  # Tag this invocation as creating a new instance.
  newInstance: ->
    base = @variable.base or @variable
    if base instanceof Call
      base.newInstance()
    else
      @isNew = true
    this

  # Grab the reference to the superclass's implementation of the current
  # method.
  superReference: (o) ->
    {method} = o.scope
    throw SyntaxError 'cannot call super outside of a function.' unless method
    {name} = method
    throw SyntaxError 'cannot call super on an anonymous function.' unless name?
    if method.klass
      (new Value (new Literal method.klass), [new Access(new Literal "__super__"), new Access new Literal name]).compile o
    else
      "#{name}.__super__.constructor"

  # Soaked chained invocations unfold into if/else ternary structures.
  unfoldSoak: (o) ->
    if @soak
      if @variable
        return ifn if ifn = unfoldSoak o, this, 'variable'
        [left, rite] = new Value(@variable).cacheReference o
      else
        left = new Literal @superReference o
        rite = new Value left
      rite = new Call rite, @args
      rite.isNew = @isNew
      left = new Literal "typeof #{ left.compile o } === \"function\""
      return new If left, new Value(rite), soak: yes
    call = this
    list = []
    loop
      if call.variable instanceof Call
        list.push call
        call = call.variable
        continue
      break unless call.variable instanceof Value
      list.push call
      break unless (call = call.variable.base) instanceof Call
    for call in list.reverse()
      if ifn
        if call.variable instanceof Call
          call.variable = ifn
        else
          call.variable.base = ifn
      ifn = unfoldSoak o, call, 'variable'
    ifn

  # Walk through the objects in the arguments, moving over simple values.
  # This allows syntax like `call a: b, c` into `call({a: b}, c);`
  filterImplicitObjects: (list) ->
    nodes = []
    for node in list
      unless node.isObject?() and node.base.generated
        nodes.push node
        continue
      obj = null
      for prop in node.base.properties
        if prop instanceof Assign
          nodes.push obj = new Obj properties = [], true if not obj
          properties.push prop
        else
          nodes.push prop
          obj = null
    nodes

  # Compile a vanilla function call.
  compileNode: (o) ->
    @variable?.front = @front
    if code = Splat.compileSplattedArray o, @args, true
      return @compileSplat o, code
    args = @filterImplicitObjects @args
    args = (arg.compile o, LEVEL_LIST for arg in args).join ', '
    if @isSuper
      @superReference(o) + ".call(this#{ args and ', ' + args })"
    else
      (if @isNew then 'new ' else '') + @variable.compile(o, LEVEL_ACCESS) + ( if @variable.base then '' else '->' ) + "(#{args})" # rr

  # `super()` is converted into a call against the superclass's implementation
  # of the current function.
  compileSuper: (args, o) ->
    "#{@superReference(o)}.call(this#{ if args.length then ', ' else '' }#{args})"

  # If you call a function with a splat, it's converted into a JavaScript
  # `.apply()` call to allow an array of arguments to be passed.
  # If it's a constructor, then things get real tricky. We have to inject an
  # inner constructor in order to be able to pass the varargs.
  compileSplat: (o, splatArgs) ->
    return "#{ @superReference o }.apply(this, #{splatArgs})" if @isSuper
    if @isNew
      idt = @tab + TAB
      return """
        (function(func, args, ctor) {
        #{idt}ctor.prototype = func.prototype;
        #{idt}var child = new ctor, result = func.apply(child, args);
        #{idt}return typeof result === "object" ? result : child;
        #{@tab}})(#{ @variable.compile o, LEVEL_LIST }, #{splatArgs}, function() {})
      """
    base = new Value @variable
    if (name = base.properties.pop()) and base.isComplex()
      ref = o.scope.freeVariable 'ref'
      fun = "(#{ref} = #{ base.compile o, LEVEL_LIST })#{ name.compile o }"
    else
      fun = base.compile o, LEVEL_ACCESS
      fun = "(#{fun})" if SIMPLENUM.test fun
      if name
        ref = fun
        fun += name.compile o
      else
        ref = 'null'
    "#{fun}.apply(#{ref}, #{splatArgs})"

#### Extends

# Node to extend an object's prototype with an ancestor object.
# After `goog.inherits` from the
# [Closure Library](http://closure-library.googlecode.com/svn/docs/closureGoogBase.js.html).
exports.Extends = class Extends extends Base
  constructor: (@child, @parent) ->

  children: ['child', 'parent']

  # Hooks one constructor into another's prototype chain.
  compile: (o) ->
    utility 'hasProp'
    new Call(new Value(new Literal utility 'extends'), [@child, @parent]).compile o

#### Access

# A `.` access into a property of a value, or the `::` shorthand for
# an access into the object's prototype.
exports.Access = class Access extends Base
  constructor: (@name, tag) ->
    @name.asKey = yes
    @proto = if tag is 'proto' then '.prototype' else ''
    @soak  = tag is 'soak'

  children: ['name']

  compile: (o) ->
    name = @name.compile o
    @proto + if IDENTIFIER.test name then "->#{name}" else "[#{name}]"

  isComplex: NO

#### Index

# A `[ ... ]` indexed access into an array or object.
exports.Index = class Index extends Base
  constructor: (@index) ->

  children: ['index']

  compile: (o) ->
    (if @proto then '.prototype' else '') + "[#{ @index.compile o, LEVEL_PAREN }]"

  isComplex: ->
    @index.isComplex()

#### Range

# A range literal. Ranges can be used to extract portions (slices) of arrays,
# to specify a range for comprehensions, or as a value, to be expanded into the
# corresponding array of integers at runtime.
exports.Range = class Range extends Base

  children: ['from', 'to']

  constructor: (@from, @to, tag) ->
    @exclusive = tag is 'exclusive'
    @equals = if @exclusive then '' else '='

  # Compiles the range's source variables -- where it starts and where it ends.
  # But only if they need to be cached to avoid double evaluation.
  compileVariables: (o) ->
    o = merge o, top: true
    [@fromC, @fromVar]  =  @from.cache o, LEVEL_LIST
    [@toC, @toVar]      =  @to.cache o, LEVEL_LIST
    [@step, @stepVar]   =  step.cache o, LEVEL_LIST if step = del o, 'step'
    [@fromNum, @toNum]  = [@fromVar.match(SIMPLENUM), @toVar.match(SIMPLENUM)]
    @stepNum            = @stepVar.match(SIMPLENUM) if @stepVar

  # When compiled normally, the range returns the contents of the *for loop*
  # needed to iterate over the values in the range. Used by comprehensions.
  compileNode: (o) ->
    console.log("Range")
    @compileVariables o unless @fromVar
    return @compileArray(o) unless o.index

    # Set up endpoints.
    known    = @fromNum and @toNum
    idx      = del o, 'index'
    varPart  = "#{idx} = #{@fromC}"
    varPart += ", #{@toC}" if @toC isnt @toVar
    varPart += ", #{@step}" if @step isnt @stepVar
    [lt, gt] = ["#{idx} <#{@equals}", "#{idx} >#{@equals}"]

    # Generate the condition.
    condPart = if @stepNum
      condPart = if +@stepNum > 0 then "#{lt} #{@toVar}" else "#{gt} #{@toVar}"
    else if known
      [from, to] = [+@fromNum, +@toNum]
      condPart   = if from <= to then "#{lt} #{to}" else "#{gt} #{to}"
    else
      cond     = "#{@fromVar} <= #{@toVar}"
      condPart = "#{cond} ? #{lt} #{@toVar} : #{gt} #{@toVar}"

    # Generate the step.
    stepPart = if @stepVar
      "#{idx} += #{@stepVar}"
    else if known
      if from <= to then "#{idx}++" else "#{idx}--"
    else
      "#{cond} ? #{idx}++ : #{idx}--"

    # The final loop body.
    "#{varPart}; #{condPart}; #{stepPart}"


  # When used as a value, expand the range into the equivalent array.
  compileArray: (o) ->
    if @fromNum and @toNum and Math.abs(@fromNum - @toNum) <= 20
      range = [+@fromNum..+@toNum]
      range.pop() if @exclusive
      return "[#{ range.join(', ') }]"
    idt    = @tab + TAB
    i      = o.scope.freeVariable 'i'
    result = o.scope.freeVariable 'results'
    pre    = "\n#{idt}#{result} = [];"
    if @fromNum and @toNum
      o.index = i
      body    = @compileNode o
    else
      vars    = "#{i} = #{@fromC}" + if @toC isnt @toVar then ", #{@toC}" else ''
      cond    = "#{@fromVar} <= #{@toVar}"
      body    = "var #{vars}; #{cond} ? #{i} <#{@equals} #{@toVar} : #{i} >#{@equals} #{@toVar}; #{cond} ? #{i}++ : #{i}--"
    post   = "{ #{result}->push(#{i}); }\n#{idt}return #{result};\n#{o.indent}"
    hasArgs = (node) -> node?.contains (n) -> n instanceof Literal and n.value is 'arguments' and not n.asKey
    args   = ', arguments' if hasArgs(@from) or hasArgs(@to)
    "(sub {#{pre}\n#{idt}for (#{body})#{post}}).apply(this#{args ? ''})"

#### Slice

# An array slice literal. Unlike JavaScript's `Array#slice`, the second parameter
# specifies the index of the end of the slice, just as the first parameter
# is the index of the beginning.
exports.Slice = class Slice extends Base

  children: ['range']

  constructor: (@range) ->
    super()

  # We have to be careful when trying to slice through the end of the array,
  # `9e9` is used because not all implementations respect `undefined` or `1/0`.
  # `9e9` should be safe because `9e9` > `2**32`, the max array length.
  compileNode: (o) ->
    {to, from} = @range
    fromStr    = from and from.compile(o, LEVEL_PAREN) or '0'
    compiled   = to and to.compile o, LEVEL_PAREN
    if to and not (not @range.exclusive and +compiled is -1)
      toStr = ', ' + if @range.exclusive
        compiled
      else if SIMPLENUM.test compiled
        (+compiled + 1).toString()
      else
        "(#{compiled} + 1) || 9e9"
    ".slice(#{ fromStr }#{ toStr or '' })"

#### Obj

# An object literal, nothing fancy.
exports.Obj = class Obj extends Base
  constructor: (props, @generated = false) ->
    @objects = @properties = props or []

  children: ['properties']

  compileNode: (o) ->
    console.log("Objs")
    props = @properties
    return (if @front then '({})' else '{}') unless props.length
    if @generated
      for node in props when node instanceof Value
        throw new Error 'cannot have an implicit value in an implicit object'
    idt         = o.indent += TAB
    lastNoncom  = @lastNonComment @properties
    props = for prop, i in props
      join = if i is props.length - 1
        ''
      else if prop is lastNoncom or prop instanceof Comment
        '\n'
      else
        ',\n'
      indent = if prop instanceof Comment then '' else idt
      if prop instanceof Value and prop.this
        prop = new Assign prop.properties[0].name, prop, 'object'
      if prop not instanceof Comment
        if prop not instanceof Assign
          prop = new Assign prop, prop, 'object'
        (prop.variable.base or prop.variable).asKey = yes
      indent + prop.compile(o, LEVEL_TOP) + join
    props = props.join ''
    obj   = "{#{ props and '\n' + props + '\n' + @tab }}"
    if @front then "(#{obj})" else obj

  assigns: (name) ->
    for prop in @properties when prop.assigns name then return yes
    no

#### Arr

# An array literal.
exports.Arr = class Arr extends Base
  constructor: (objs) ->
    @objects = objs or []

  children: ['objects']

  filterImplicitObjects: Call::filterImplicitObjects

  compileNode: (o) ->
    return '[]' unless @objects.length
    o.indent += TAB
    objs = @filterImplicitObjects @objects
    return code if code = Splat.compileSplattedArray o, objs
    code = (obj.compile o, LEVEL_LIST for obj in objs).join ', '
    if code.indexOf('\n') >= 0
      "[\n#{o.indent}#{code}\n#{@tab}]"
    else
      "[#{code}]"

  assigns: (name) ->
    for obj in @objects when obj.assigns name then return yes
    no

#### Class

# The CoffeeScript class definition.
# Initialize a **Class** with its name, an optional superclass, and a
# list of prototype property assignments.
exports.Class = class Class extends Base
  constructor: (@variable, @parent, @body = new Block) ->
    @boundFuncs = []
    @body.classBody = yes

  children: ['variable', 'parent', 'body']

  # Figure out the appropriate name for the constructor function of this class.
  determineName: ->
    return null unless @variable
    decl = if tail = last @variable.properties
      tail instanceof Access and tail.name.value
    else
      @variable.base.value
    decl and= IDENTIFIER.test(decl) and decl

  # For all `this`-references and bound functions in the class definition,
  # `this` is the Class being constructed.
  setContext: (name) ->
    @body.traverseChildren false, (node) ->
      return false if node.classBody
      if node instanceof Literal and node.value is 'this'
        node.value    = name
      else if node instanceof Code
        node.klass    = name
        node.context  = name if node.bound

  # Ensure that all functions bound to the instance are proxied in the
  # constructor.
  addBoundFunctions: (o) ->
    if @boundFuncs.length
      for bvar in @boundFuncs
        lhs = (new Value (new Literal "this"), [new Access bvar]).compile o
        @ctor.body.unshift new Literal "#{lhs} = #{utility 'bind'}(#{lhs}, this)"

  # Merge the properties from a top-level object as prototypal properties
  # on the class.
  addProperties: (node, name, o) ->
    props = node.base.properties.slice 0
    exprs = while assign = props.shift()
      if assign instanceof Assign
        base = assign.variable.base
        delete assign.context
        func = assign.value
        if base.value is 'constructor'
          if @ctor
            throw new Error 'cannot define more than one constructor in a class'
          if func.bound
            throw new Error 'cannot define a constructor as a bound function'
          if func instanceof Code
            assign = @ctor = func
          else
            @externalCtor = o.scope.freeVariable 'class'
            assign = new Assign new Literal(@externalCtor), func
        else
          unless assign.variable.this
            assign.variable = new Value(new Literal(name), [new Access(base, 'proto')])
          if func instanceof Code and func.bound
            @boundFuncs.push base
            func.bound = no
      assign
    compact exprs

  # Walk the body of the class, looking for prototype properties to be converted.
  walkBody: (name, o) ->
    @traverseChildren false, (child) =>
      return false if child instanceof Class
      if child instanceof Block
        for node, i in exps = child.expressions
          if node instanceof Value and node.isObject(true)
            exps[i] = @addProperties node, name, o
        child.expressions = exps = flatten exps

  # Make sure that a constructor is defined for the class, and properly
  # configured.
  ensureConstructor: (name) ->
    if not @ctor
      @ctor = new Code
      @ctor.body.push new Literal "#{name}.__super__.constructor.apply(this, arguments)" if @parent
      @ctor.body.push new Literal "#{@externalCtor}.apply(this, arguments)" if @externalCtor
      @body.expressions.unshift @ctor
    @ctor.ctor     = @ctor.name = name
    @ctor.klass    = null
    @ctor.noReturn = yes

  # Instead of generating the JavaScript string directly, we build up the
  # equivalent syntax tree and compile that, in pieces. You can see the
  # constructor, property assignments, and inheritance getting built out below.
  compileNode: (o) ->
    decl  = @determineName()
    name  = decl or @name or '_Class'
    lname = new Literal name

    @setContext name
    @walkBody name, o
    @ensureConstructor name
    @body.expressions.unshift new Extends lname, @parent if @parent
    @body.expressions.unshift @ctor unless @ctor instanceof Code
    @body.expressions.push lname
    @addBoundFunctions o

    klass = new Parens Closure.wrap(@body), true
    klass = new Assign @variable, klass if @variable
    klass.compile o

#### Assign

# The **Assign** is used to assign a local variable to value, or to set the
# property of an object -- including within object literals.
exports.Assign = class Assign extends Base
  constructor: (@variable, @value, @context, options) ->
    @param = options and options.param

  children: ['variable', 'value']

  assigns: (name) ->
    @[if @context is 'object' then 'value' else 'variable'].assigns name

  unfoldSoak: (o) ->
    unfoldSoak o, this, 'variable'

  # Compile an assignment, delegating to `compilePatternMatch` or
  # `compileSplice` if appropriate. Keep track of the name of the base object
  # we've been assigned to, for correct internal references. If the variable
  # has not been seen yet within the current scope, declare it.
  compileNode: (o) ->
    if isValue = @variable instanceof Value
      return @compilePatternMatch o if @variable.isArray() or @variable.isObject()
      return @compileSplice       o if @variable.isSplice()
      return @compileConditional  o if @context in ['||=', '&&=', '?=']
    name = @variable.compile o, LEVEL_LIST
    unless @context or @variable.isAssignable()
      throw SyntaxError "\"#{ @variable.compile o }\" cannot be assigned."
    unless @context or isValue and (@variable.namespaced or @variable.hasProperties())
      if @param
        o.scope.add name, 'var'
      else
        o.scope.find name
    if @value instanceof Code and match = METHOD_DEF.exec name
      @value.klass = match[1] if match[1]
      @value.name  = match[2] ? match[3] ? match[4] ? match[5]
    val = @value.compile o, LEVEL_LIST
    return "#{name}=> #{val}" if @context is 'object'
    val = '$' + name + " #{ @context or '=' } " + val   # xx = 10  rr
    if o.level <= LEVEL_LIST then val else "(#{val})"

  # Brief implementation of recursive pattern matching, when assigning array or
  # object literals to a value. Peeks at their properties to assign inner names.
  # See the [ECMAScript Harmony Wiki](http://wiki.ecmascript.org/doku.php?id=harmony:destructuring)
  # for details.
  compilePatternMatch: (o) ->
    top       = o.level is LEVEL_TOP
    {value}   = this
    {objects} = @variable.base
    unless olen = objects.length
      code = value.compile o
      return if o.level >= LEVEL_OP then "(#{code})" else code
    isObject = @variable.isObject()
    if top and olen is 1 and (obj = objects[0]) not instanceof Splat
      # Unroll simplest cases: `{v} = x` -> `v = x.v`
      if obj instanceof Assign
        {variable: {base: idx}, value: obj} = obj
      else
        if obj.base instanceof Parens
          [obj, idx] = new Value(obj.unwrapAll()).cacheReference o
        else
          idx = if isObject
            if obj.this then obj.properties[0].name else obj
          else
            new Literal 0
      acc   = IDENTIFIER.test idx.unwrap().value or 0
      value = new Value value
      value.properties.push new (if acc then Access else Index) idx
      return new Assign(obj, value, null, param: @param).compile o, LEVEL_TOP
    vvar    = value.compile o, LEVEL_LIST
    assigns = []
    splat   = false
    if not IDENTIFIER.test(vvar) or @variable.assigns(vvar)
      assigns.push "#{ ref = o.scope.freeVariable 'ref' } = #{vvar}"
      vvar = ref
    for obj, i in objects
      # A regular array pattern-match.
      idx = i
      if isObject
        if obj instanceof Assign
          # A regular object pattern-match.
          {variable: {base: idx}, value: obj} = obj
        else
          # A shorthand `{a, b, @c} = val` pattern-match.
          if obj.base instanceof Parens
            [obj, idx] = new Value(obj.unwrapAll()).cacheReference o
          else
            idx = if obj.this then obj.properties[0].name else obj
      if not splat and obj instanceof Splat
        val = "#{olen} <= #{vvar}.length ? #{ utility 'slice' }.call(#{vvar}, #{i}"
        if rest = olen - i - 1
          ivar = o.scope.freeVariable 'i'
          val += ", #{ivar} = #{vvar}.length - #{rest}) : (#{ivar} = #{i}, [])"
        else
          val += ") : []"
        val   = new Literal val
        splat = "#{ivar}++"
      else
        if obj instanceof Splat
          obj = obj.name.compile o
          throw SyntaxError \
            "multiple splats are disallowed in an assignment: #{obj} ..."
        if typeof idx is 'number'
          idx = new Literal splat or idx
          acc = no
        else
          acc = isObject and IDENTIFIER.test idx.unwrap().value or 0
        val = new Value new Literal(vvar), [new (if acc then Access else Index) idx]
      assigns.push new Assign(obj, val, null, param: @param).compile o, LEVEL_TOP
    assigns.push vvar unless top
    code = assigns.join ', '
    if o.level < LEVEL_LIST then code else "(#{code})"

  # When compiling a conditional assignment, take care to ensure that the
  # operands are only evaluated once, even though we have to reference them
  # more than once.
  compileConditional: (o) ->
    [left, rite] = @variable.cacheReference o
    if "?" in @context then o.isExistentialEquals = true
    new Op(@context.slice(0, -1), left, new Assign(rite, @value, '=') ).compile o

  # Compile the assignment from an array splice literal, using JavaScript's
  # `Array#splice` method.
  compileSplice: (o) ->
    {range: {from, to, exclusive}} = @variable.properties.pop()
    name = @variable.compile o
    [fromDecl, fromRef] = from?.cache(o, LEVEL_OP) or ['0', '0']
    if to
      if from?.isSimpleNumber() and to.isSimpleNumber()
        to = +to.compile(o) - +fromRef
        to += 1 unless exclusive
      else
        to = to.compile(o) + ' - ' + fromRef
        to += ' + 1' unless exclusive
    else
      to = "9e9"
    [valDef, valRef] = @value.cache o, LEVEL_LIST
    code = "[].splice.apply(#{name}, [#{fromDecl}, #{to}].concat(#{valDef})), #{valRef}"
    if o.level > LEVEL_TOP then "(#{code})" else code

#### Code

# A function definition. This is the only node that creates a new Scope.
# When for the purposes of walking the contents of a function body, the Code
# has no *children* -- they're within the inner scope.
exports.Code = class Code extends Base
  constructor: (params, body, tag) ->
    @params  = params or []
    @body    = body or new Block
    @bound   = tag is 'boundfunc'
    @context = 'this' if @bound

  children: ['params', 'body']

  isStatement: -> !!@ctor

  jumps: NO

  # Compilation creates a new scope unless explicitly asked to share with the
  # outer scope. Handles splat parameters in the parameter list by peeking at
  # the JavaScript `arguments` objects. If the function is bound with the `=>`
  # arrow, generates a wrapper that saves the current value of `this` through
  # a closure.
  compileNode: (o) ->
    o.scope         = new Scope o.scope, @body, this
    o.scope.shared  = del o, 'sharedScope'
    o.indent        += TAB
    delete o.bare
    vars   = []
    exprs  = []
    for param in @params when param.splat
      o.scope.add p.name.value, 'var', yes for p in @params when p.name.value
      splats = new Assign new Value(new Arr(p.asReference o for p in @params)),
                          new Value new Literal 'arguments'
      break
    for param in @params
      if param.isComplex()
        val = ref = param.asReference o
        val = new Op '?', ref, param.value if param.value
        exprs.push new Assign new Value(param.name), val, '=', param: yes
      else
        ref = param
        if param.value
          lit = new Literal ref.name.value + ' == null'
          val = new Assign new Value(param.name), param.value, '='
          exprs.push new If lit, val
      vars.push ref unless splats
    wasEmpty = @body.isEmpty()
    exprs.unshift splats if splats
    @body.expressions.unshift exprs... if exprs.length
    o.scope.parameter vars[i] = v.compile o for v, i in vars unless splats
    @body.makeReturn() unless wasEmpty or @noReturn
    idt   = o.indent
    code  = "sub {"
    code  += ' ' + @name if @ctor
    code  += " my ( $" + vars.join(', $') + ' )=@_;' if vars.length  # rr
    code  += "\n#{ @body.compileWithDeclarations o }\n#{@tab}" unless @body.isEmpty()
    code  += '}'
    return @tab + code if @ctor
    return utility('bind') + "(#{code}, #{@context})" if @bound
    if @front or (o.level >= LEVEL_ACCESS) then "(#{code})" else code

  # Short-circuit `traverseChildren` method to prevent it from crossing scope boundaries
  # unless `crossScope` is `true`.
  traverseChildren: (crossScope, func) ->
    super(crossScope, func) if crossScope

#### Param

# A parameter in a function definition. Beyond a typical Javascript parameter,
# these parameters can also attach themselves to the context of the function,
# as well as be a splat, gathering up a group of parameters into an array.
exports.Param = class Param extends Base
  constructor: (@name, @value, @splat) ->

  children: ['name', 'value']

  compile: (o) ->
    console.log "Param"
    @name.compile o, LEVEL_LIST

  asReference: (o) ->
    return @reference if @reference
    node = @name
    if node.this
      node = node.properties[0].name
      node = new Literal '_' + node.value if node.value.reserved
    else if node.isComplex()
      node = new Literal o.scope.freeVariable 'arg'
    node = new Value node
    node = new Splat node if @splat
    @reference = node

  isComplex: ->
    @name.isComplex()

#### Splat

# A splat, either as a parameter to a function, an argument to a call,
# or as part of a destructuring assignment.
exports.Splat = class Splat extends Base

  children: ['name']

  isAssignable: YES

  constructor: (name) ->
    @name = if name.compile then name else new Literal name

  assigns: (name) ->
    @name.assigns name

  compile: (o) ->
    console.log "Splat"
    if @index? then @compileParam o else @name.compile o

  # Utility function that converts arbitrary number of elements, mixed with
  # splats, to a proper array.
  @compileSplattedArray: (o, list, apply) ->
    index = -1
    continue while (node = list[++index]) and node not instanceof Splat
    return '' if index >= list.length
    if list.length is 1
      code = list[0].compile o, LEVEL_LIST
      return code if apply
      return "#{ utility 'slice' }.call(#{code})"
    args = list.slice index
    for node, i in args
      code = node.compile o, LEVEL_LIST
      args[i] = if node instanceof Splat
      then "#{ utility 'slice' }.call(#{code})"
      else "[#{code}]"
    return args[0] + ".concat(#{ args.slice(1).join ', ' })" if index is 0
    base = (node.compile o, LEVEL_LIST for node in list.slice 0, index)
    "[#{ base.join ', ' }].concat(#{ args.join ', ' })"

#### While

# A while loop, the only sort of low-level loop exposed by CoffeeScript. From
# it, all other loops can be manufactured. Useful in cases where you need more
# flexibility or more speed than a comprehension can provide.
exports.While = class While extends Base
  constructor: (condition, options) ->
    @condition = if options?.invert then condition.invert() else condition
    @guard     = options?.guard

  children: ['condition', 'guard', 'body']

  isStatement: YES

  makeReturn: ->
    @returns = yes
    this

  addBody: (@body) ->
    this

  jumps: ->
    {expressions} = @body
    return no unless expressions.length
    for node in expressions
      return node if node.jumps loop: yes
    no

  # The main difference from a JavaScript *while* is that the CoffeeScript
  # *while* can be used as a part of a larger expression -- while loops may
  # return an array containing the computed result of each iteration.
  compileNode: (o) ->
    o.indent += TAB
    set      = ''
    {body}   = this
    if body.isEmpty()
      body = ''
    else
      if o.level > LEVEL_TOP or @returns
        rvar = o.scope.freeVariable 'results'
        set  = "#{@tab}#{rvar} = [];\n"
        body = Push.wrap rvar, body if body
      body = Block.wrap [new If @guard, body] if @guard
      body = "\n#{ body.compile o, LEVEL_TOP }\n#{@tab}"
    code = set + @tab + "while (#{ @condition.compile o, LEVEL_PAREN }) {#{body}}"
    if @returns
      code += "\n#{@tab}return #{rvar};"
    code

#### Op

# Simple Arithmetic and logical operations. Performs some conversion from
# CoffeeScript operations into their JavaScript equivalents.
exports.Op = class Op extends Base
  constructor: (op, first, second, flip ) ->
    return new In first, second if op is 'in'
    if op is 'do'
      call = new Call first, first.params or []
      call.do = yes
      return call
    if op is 'new'
      return first.newInstance() if first instanceof Call and not first.do
      first = new Parens first   if first instanceof Code and first.bound or first.do
    @operator = CONVERSIONS[op] or op
    @first    = first
    @second   = second
    @flip     = !!flip
    return this

  # The map of conversions from CoffeeScript to JavaScript symbols.
  CONVERSIONS =
    '==': '==='
    '!=': '!=='
    'of': 'in'

  # The map of invertible operators.
  INVERSIONS =
    '!==': '==='
    '===': '!=='

  children: ['first', 'second']

  isSimpleNumber: NO

  isUnary: ->
    not @second

  isComplex: ->
    not (@isUnary() and (@operator in ['+', '-'])) or @first.isComplex()

  # Am I capable of
  # [Python-style comparison chaining](http://docs.python.org/reference/expressions.html#notin)?
  isChainable: ->
    @operator in ['<', '>', '>=', '<=', '===', '!==']

  invert: ->
    if @isChainable() and @first.isChainable()
      allInvertable = yes
      curr = this
      while curr and curr.operator
        allInvertable and= (curr.operator of INVERSIONS)
        curr = curr.first
      return new Parens(this).invert() unless allInvertable
      curr = this
      while curr and curr.operator
        curr.invert = !curr.invert
        curr.operator = INVERSIONS[curr.operator]
        curr = curr.first
      this
    else if op = INVERSIONS[@operator]
      @operator = op
      if @first.unwrap() instanceof Op
        @first.invert()
      this
    else if @second
      new Parens(this).invert()
    else if @operator is '!' and (fst = @first.unwrap()) instanceof Op and
                                  fst.operator in ['!', 'in', 'instanceof']
      fst
    else
      new Op '!', this

  unfoldSoak: (o) ->
    @operator in ['++', '--', 'delete'] and unfoldSoak o, this, 'first'

  compileNode: (o) ->
    console.log("Op")
    return @compileUnary     o if @isUnary()
    return @compileChain     o if @isChainable() and @first.isChainable()
    return @compileExistence o if @operator is '?'
    @first.front = @front
    code = @first.compile(o, LEVEL_OP) + ' ' + @operator + ' ' +
           @second.compile(o, LEVEL_OP)
    if o.level <= LEVEL_OP then code else "(#{code})"

  # Mimic Python's chained comparisons when multiple comparison operators are
  # used sequentially. For example:
  #
  #     bin/coffee -e 'console.log 50 < 65 > 10'
  #     true
  compileChain: (o) ->
    [@first.second, shared] = @first.second.cache o
    fst = @first.compile o, LEVEL_OP
    code = "#{fst} #{if @invert then '&&' else '||'} #{ shared.compile o } #{@operator} #{ @second.compile o, LEVEL_OP }"
    "(#{code})"

  compileExistence: (o) ->
    if @first.isComplex()
      ref = new Literal o.scope.freeVariable 'ref'
      fst = new Parens new Assign ref, @first
    else
      fst = @first
      ref = fst
    new If(new Existence(fst), ref, type: 'if').addElse(@second).compile o

  # Compile a unary **Op**.
  compileUnary: (o) ->
    parts = [op = @operator]
    parts.push ' ' if op in ['new', 'typeof', 'delete'] or
                      op in ['+', '-'] and @first instanceof Op and @first.operator is op
    @first = new Parens @first if op is 'new' and @first.isStatement o
    parts.push @first.compile o, LEVEL_OP
    parts.reverse() if @flip
    parts.join ''

  toString: (idt) ->
    super idt, @constructor.name + ' ' + @operator

#### In
exports.In = class In extends Base
  constructor: (@object, @array) ->

  children: ['object', 'array']

  invert: NEGATE

  compileNode: (o) ->
    console.log("In")
    if @array instanceof Value and @array.isArray()
      for obj in @array.base.objects when obj instanceof Splat
        hasSplat = yes
        break
      # `compileOrTest` only if we have an array literal with no splats
      return @compileOrTest o unless hasSplat
    @compileLoopTest o

  compileOrTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_OP
    [cmp, cnj] = if @negated then [' !== ', ' && '] else [' == ', ' || ']
    tests = for item, i in @array.base.objects
      (if i then ref else sub) + cmp + item.compile o, LEVEL_OP
    return 'false' if tests.length is 0
    tests = tests.join cnj
    if o.level < LEVEL_OP then tests else "(#{tests})"

  compileLoopTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_LIST
    code = utility('indexOf') + ".call(#{ @array.compile o, LEVEL_LIST }, #{ref}) " +
           if @negated then '< 0' else '>= 0'
    return code if sub is ref
    code = sub + ', ' + code
    if o.level < LEVEL_LIST then code else "(#{code})"

  toString: (idt) ->
    super idt, @constructor.name + if @negated then '!' else ''

#### Try

# A classic *try/catch/finally* block.
exports.Try = class Try extends Base
  constructor: (@attempt, @error, @recovery, @ensure) ->

  children: ['attempt', 'recovery', 'ensure']

  isStatement: YES

  jumps: (o) -> @attempt.jumps(o) or @recovery?.jumps(o)

  makeReturn: ->
    @attempt  = @attempt .makeReturn() if @attempt
    @recovery = @recovery.makeReturn() if @recovery
    this

  # Compilation is more or less as you would expect -- the *finally* clause
  # is optional, the *catch* is not.
  compileNode: (o) ->
    console.log("Try")
    o.indent  += TAB
    errorPart = if @error then " (#{ @error.compile o }) " else ' '
    catchPart = if @recovery
      " catch#{errorPart}{\n#{ @recovery.compile o, LEVEL_TOP }\n#{@tab}}"
    else unless @ensure or @recovery
      ' if ($@) {}'
    """
    #{@tab}eval {
    #{ @attempt.compile o, LEVEL_TOP }
    #{@tab}}#{ catchPart or '' }
    """ + if @ensure then " finally {\n#{ @ensure.compile o, LEVEL_TOP }\n#{@tab}}" else ''

#### Throw

# Simple node to throw an exception.
exports.Throw = class Throw extends Base
  constructor: (@expression) ->

  children: ['expression']

  isStatement: YES
  jumps:       NO

  # A **Throw** is already a return, of sorts...
  makeReturn: THIS

  compileNode: (o) ->
    @tab + "throw #{ @expression.compile o };"

#### Existence

# Checks a variable for existence -- not *null* and not *undefined*. This is
# similar to `.nil?` in Ruby, and avoids having to consult a JavaScript truth
# table.
exports.Existence = class Existence extends Base
  constructor: (@expression) ->

  children: ['expression']

  invert: NEGATE

  compileNode: (o) ->
    console.log("Existence")
    code = @expression.compile o, LEVEL_OP
    code = if IDENTIFIER.test(code) and not o.scope.check code
        [cmp, cnj] = if @negated then ['===', '||'] else ['!==', '&&']
        "typeof #{code} #{cmp} \"undefined\" #{cnj} #{code} #{cmp} null"
    else
      # do not use strict equality here; it will break existing code
      "#{code} #{if @negated then '==' else '!='} null"
    if o.level <= LEVEL_COND then code else "(#{code})"

#### Parens

# An extra set of parentheses, specified explicitly in the source. At one time
# we tried to clean up the results by detecting and removing redundant
# parentheses, but no longer -- you can put in as many as you please.
#
# Parentheses are a good way to force any statement to become an expression.
exports.Parens = class Parens extends Base
  constructor: (@body) ->

  children: ['body']

  unwrap    : -> @body
  isComplex : -> @body.isComplex()
  makeReturn: -> @body.makeReturn()

  compileNode: (o) ->
    console.log("Parens")
    expr = @body.unwrap()
    if expr instanceof Value and expr.isAtomic()
      expr.front = @front
      return expr.compile o
    code = expr.compile o, LEVEL_PAREN
    bare = o.level < LEVEL_OP and (expr instanceof Op or expr instanceof Call or
      (expr instanceof For and expr.returns))
    if bare then code else "(#{code})"

#### For

# CoffeeScript's replacement for the *for* loop is our array and object
# comprehensions, that compile into *for* loops here. They also act as an
# expression, able to return the result of each filtered iteration.
#
# Unlike Python array comprehensions, they can be multi-line, and you can pass
# the current index of the loop as a second parameter. Unlike Ruby blocks,
# you can map and filter in a single pass.
exports.For = class For extends Base
  constructor: (body, source) ->
    {@source, @guard, @step, @name, @index} = source
    @body    = Block.wrap [body]
    @own     = !!source.own
    @object  = !!source.object
    [@name, @index] = [@index, @name] if @object
    throw SyntaxError 'index cannot be a pattern matching expression' if @index instanceof Value
    @range   = @source instanceof Value and @source.base instanceof Range and not @source.properties.length
    @pattern = @name instanceof Value
    throw SyntaxError 'indexes do not apply to range loops' if @range and @index
    throw SyntaxError 'cannot pattern match over range loops' if @range and @pattern
    @returns = false

  children: ['body', 'source', 'guard', 'step']

  isStatement: YES

  jumps: While::jumps

  makeReturn: ->
    @returns = yes
    this

  # Welcome to the hairiest method in all of CoffeeScript. Handles the inner
  # loop, filtering, stepping, and result saving for array, object, and range
  # comprehensions. Some of the generated code can be shared in common, and
  # some cannot.
  compileNode: (o) ->
    console.log("For")
    body      = Block.wrap [@body]
    lastJumps = last(body.expressions)?.jumps()
    @returns  = no if lastJumps and lastJumps instanceof Return
    source    = if @range then @source.base else @source
    scope     = o.scope
    name      = @name  and @name.compile o, LEVEL_LIST
    index     = @index and @index.compile o, LEVEL_LIST
    scope.find(name,  immediate: yes) if name and not @pattern
    scope.find(index, immediate: yes) if index
    rvar      = scope.freeVariable 'results' if @returns
    ivar      = (if @range then name else index) or scope.freeVariable 'i'
    ivar      = "$#{ivar}" # rr
    rvar      = "$#{rvar}" # rr
    # the `_by` variable is created twice in `Range`s if we don't prevent it from being declared here
    stepvar   = scope.freeVariable "step" if @step and not @range
    name      = ivar if @pattern
    varPart   = ''
    guardPart = ''
    defPart   = ''
    idt1      = @tab + TAB
    if @range
      forPart = source.compile merge(o, {index: ivar, @step})
    else
      svar    = @source.compile o, LEVEL_LIST
      if (name or @own) and not IDENTIFIER.test svar
        defPart    = "#{@tab}#{ref = scope.freeVariable 'ref'} = #{svar};\n"
        svar       = ref
      if name and not @pattern
        namePart   = "#{name} = #{svar}[#{ivar}]"
      unless @object
        lvar       = scope.freeVariable 'len'
        forVarPart = "#{ivar} = 0, #{lvar} = #{svar}.length" + if @step then ", #{stepvar} = #{@step.compile(o, LEVEL_OP)}" else ''
        stepPart   = if @step then "#{ivar} += #{stepvar}" else "#{ivar}++"
        forPart    = "#{forVarPart}; #{ivar} < #{lvar}; #{stepPart}"
    if @returns
      resultPart   = "#{@tab}#{rvar} = [];\n"
      returnResult = "\n#{@tab}return #{rvar};"
      body         = Push.wrap rvar, body
    if @guard
      body         = Block.wrap [new If @guard, body]
    if @pattern
      body.expressions.unshift new Assign @name, new Literal "#{svar}[#{ivar}]"
    defPart     += @pluckDirectCall o, body
    varPart     = "\n#{idt1}#{namePart};" if namePart
    if @object
      forPart   = "#{ivar} in #{svar}"
      guardPart = "\n#{idt1}if (!#{utility('hasProp')}.call(#{svar}, #{ivar})) continue;" if @own
    body        = body.compile merge(o, indent: idt1), LEVEL_TOP
    body        = '\n' + body + '\n' if body
    """
    #{defPart}#{resultPart or ''}#{@tab}for (#{forPart}) {#{guardPart}#{varPart}#{body}#{@tab}}#{returnResult or ''}
    """

  pluckDirectCall: (o, body) ->
    defs = ''
    for expr, idx in body.expressions
      expr = expr.unwrapAll()
      continue unless expr instanceof Call
      val = expr.variable.unwrapAll()
      continue unless (val instanceof Code) or
                      (val instanceof Value and
                      val.base?.unwrapAll() instanceof Code and
                      val.properties.length is 1 and
                      val.properties[0].name?.value in ['call', 'apply'])
      fn    = val.base?.unwrapAll() or val
      ref   = new Literal o.scope.freeVariable 'fn'
      base  = new Value ref
      if val.base
        [val.base, base] = [base, val]
        args.unshift new Literal 'this'
      body.expressions[idx] = new Call base, expr.args
      defs += @tab + new Assign(ref, fn).compile(o, LEVEL_TOP) + ';\n'
    defs

#### Switch

# A JavaScript *switch* statement. Converts into a returnable expression on-demand.
exports.Switch = class Switch extends Base
  constructor: (@subject, @cases, @otherwise) ->

  children: ['subject', 'cases', 'otherwise']

  isStatement: YES

  jumps: (o = {block: yes}) ->
    for [conds, block] in @cases
      return block if block.jumps o
    @otherwise?.jumps o

  makeReturn: ->
    pair[1].makeReturn() for pair in @cases
    @otherwise?.makeReturn()
    this

  compileNode: (o) ->
    idt1 = o.indent + TAB
    idt2 = o.indent = idt1 + TAB
    code = @tab + "switch (#{ @subject?.compile(o, LEVEL_PAREN) or false }) {\n"
    for [conditions, block], i in @cases
      for cond in flatten [conditions]
        cond  = cond.invert() unless @subject
        code += idt1 + "case #{ cond.compile o, LEVEL_PAREN }:\n"
      code += body + '\n' if body = block.compile o, LEVEL_TOP
      break if i is @cases.length - 1 and not @otherwise
      expr = @lastNonComment block.expressions
      continue if expr instanceof Return or (expr instanceof Literal and expr.jumps() and expr.value isnt 'debugger')
      code += idt2 + 'last;\n'
    code += idt1 + "default:\n#{ @otherwise.compile o, LEVEL_TOP }\n" if @otherwise and @otherwise.expressions.length
    code +  @tab + '}'

#### If

# *If/else* statements. Acts as an expression by pushing down requested returns
# to the last line of each clause.
#
# Single-expression **Ifs** are compiled into conditional operators if possible,
# because ternaries are already proper expressions, and don't need conversion.
exports.If = class If extends Base
  constructor: (condition, @body, options = {}) ->
    @condition = if options.type is 'unless' then condition.invert() else condition
    @elseBody  = null
    @isChain   = false
    {@soak}    = options

  children: ['condition', 'body', 'elseBody']

  bodyNode:     -> @body?.unwrap()
  elseBodyNode: -> @elseBody?.unwrap()

  # Rewrite a chain of **Ifs** to add a default case as the final *else*.
  addElse: (elseBody) ->
    if @isChain
      @elseBodyNode().addElse elseBody
    else
      @isChain  = elseBody instanceof If
      @elseBody = @ensureBlock elseBody
    this

  # The **If** only compiles into a statement if either of its bodies needs
  # to be a statement. Otherwise a conditional operator is safe.
  isStatement: (o) ->
    o?.level is LEVEL_TOP or
      @bodyNode().isStatement(o) or @elseBodyNode()?.isStatement(o)

  jumps: (o) -> @body.jumps(o) or @elseBody?.jumps(o)

  compileNode: (o) ->
    if @isStatement o then @compileStatement o else @compileExpression o

  makeReturn: ->
    @body     and= new Block [@body.makeReturn()]
    @elseBody and= new Block [@elseBody.makeReturn()]
    this

  ensureBlock: (node) ->
    if node instanceof Block then node else new Block [node]

  # Compile the **If** as a regular *if-else* statement. Flattened chains
  # force inner *else* bodies into statement form.
  compileStatement: (o) ->
    child    = del o, 'chainChild'
    exeq     = del o, 'isExistentialEquals'

    if exeq
      return new If(@condition.invert(), @elseBodyNode(), type: 'if').compile o

    cond     = @condition.compile o, LEVEL_PAREN
    o.indent += TAB
    body     = @ensureBlock(@body).compile o
    body     = "\n#{body}\n#{@tab}" if body
    ifPart   = "if (#{cond}) {#{body}}"
    ifPart   = @tab + ifPart unless child
    return ifPart unless @elseBody
    ifPart + ' else ' + if @isChain
      o.indent = @tab
      o.chainChild = yes
      @elseBody.unwrap().compile o, LEVEL_TOP
    else
      "{\n#{ @elseBody.compile o, LEVEL_TOP }\n#{@tab}}"

  # Compile the If as a conditional operator.
  compileExpression: (o) ->
    cond = @condition.compile o, LEVEL_COND
    body = @bodyNode().compile o, LEVEL_LIST
    alt  = if @elseBodyNode() then @elseBodyNode().compile(o, LEVEL_LIST) else 'void 0'
    code = "#{cond} ? #{body} : #{alt}"
    if o.level >= LEVEL_COND then "(#{code})" else code

  unfoldSoak: ->
    @soak and this

# Faux-Nodes
# ----------
# Faux-nodes are never created by the grammar, but are used during code
# generation to generate other combinations of nodes.

#DeRefArr =  #rr wrap: (name) -> "@{ #{name} || [] }"

#### Push

# The **Push** creates the tree for `array.push(value)`,
# which is helpful for recording the result arrays from comprehensions.
Push =
  wrap: (name, exps) ->
    return exps if exps.isEmpty() or last(exps.expressions).jumps()
    exps.push new Call new Value(new Literal 'push' ), [new DeRefArr( name ), exps.pop()]

exports.DeRefArr = class DeRefArr extends Base
  constructor: (@value) ->

  compileNode: (o) ->
    "@{ #{@value} || [] }"

#### Closure

# A faux-node used to wrap an expressions body in a closure.
Closure =

  # Wrap the expressions body, unless it contains a pure statement,
  # in which case, no dice. If the body mentions `this` or `arguments`,
  # then make sure that the closure wrapper preserves the original values.
  wrap: (expressions, statement, noReturn) ->
    return expressions if expressions.jumps()
    func = new Code [], Block.wrap [expressions]
    args = []
    if (mentionsArgs = expressions.contains @literalArgs) or expressions.contains @literalThis
      meth = new Literal if mentionsArgs then 'apply' else 'call'
      args = [new Literal 'this']
      args.push new Literal 'arguments' if mentionsArgs
      func = new Value func, [new Access meth]
    func.noReturn = noReturn
    call = new Call func, args
    if statement then Block.wrap [call] else call

  literalArgs: (node) ->
    node instanceof Literal and node.value is 'arguments' and not node.asKey
  literalThis: (node) ->
    (node instanceof Literal and node.value is 'this' and not node.asKey) or
      (node instanceof Code and node.bound)

# Unfold a node's child if soak, then tuck the node under created `If`
unfoldSoak = (o, parent, name) ->
  return unless ifn = parent[name].unfoldSoak o
  parent[name] = ifn.body
  ifn.body = new Value parent
  ifn

# Constants
# ---------

UTILITIES =

  # Correctly set up a prototype chain for inheritance, including a reference
  # to the superclass for `super()` calls, and copies of any static properties.
  extends: '''
    function(child, parent) {
      for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; }
      function ctor() { this.constructor = child; }
      ctor.prototype = parent.prototype;
      child.prototype = new ctor;
      child.__super__ = parent.prototype;
      return child;
    }
  '''

  # Create a function bound to the current value of "this".
  bind: '''
    function(fn, me){ return function(){ return fn.apply(me, arguments); }; }
  '''

  # Discover if an item is in an array.
  indexOf: '''
    Array.prototype.indexOf || function(item) {
      for (var i = 0, l = this.length; i < l; i++) {
        if (this[i] === item) return i;
      }
      return -1;
    }
  '''

  # Shortcuts to speed up the lookup time for native functions.
  hasProp: 'Object.prototype.hasOwnProperty'
  slice  : 'Array.prototype.slice'

# Levels indicates a node's position in the AST. Useful for knowing if
# parens are necessary or superfluous.
LEVEL_TOP    = 1  # ...;
LEVEL_PAREN  = 2  # (...)
LEVEL_LIST   = 3  # [...]
LEVEL_COND   = 4  # ... ? x : y
LEVEL_OP     = 5  # !...
LEVEL_ACCESS = 6  # ...[0]

# Tabs are two spaces for pretty printing.
TAB = '  '

IDENTIFIER_STR = "[$A-Za-z_\\x7f-\\uffff][$\\w\\x7f-\\uffff]*"
IDENTIFIER = /// ^ #{IDENTIFIER_STR} $ ///
SIMPLENUM  = /^[+-]?\d+$/
METHOD_DEF = ///
  ^
    (?:
      (#{IDENTIFIER_STR})
      \.prototype
      (?:
        \.(#{IDENTIFIER_STR})
      | \[("(?:[^\\"\r\n]|\\.)*"|'(?:[^\\'\r\n]|\\.)*')\]
      | \[(0x[\da-fA-F]+ | \d*\.?\d+ (?:[eE][+-]?\d+)?)\]
      )
    )
  |
    (#{IDENTIFIER_STR})
  $
///

# Is a literal value a string?
IS_STRING = /^['"]/

# Utility Functions
# -----------------

# Helper for ensuring that utility functions are assigned at the top level.
utility = (name) ->
  ref = "__#{name}"
  Scope.root.assign ref, UTILITIES[name]
  ref

multident = (code, tab) ->
  code.replace /\n/g, '$&' + tab
