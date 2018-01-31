
#[
Here we define the Lilt interpreter.
Though in the future Lilt may become a compiled language,
an interpreter works for now. I want to get all the features
planned and implemented before writing a compiler.

The interpreter works by representing different Lilt
constructs as Nim constructs. This process is referred to
as translation.
Lilt code is translated into Nim code, and a full Lilt
program is mapped to a Nim procedure on a file.
]#

import tables
import strutils
import sequtils
import options

import outer_ast
import inner_ast
import strfix
import types
import base
import misc
import builtins

proc hls(rv: RuleVal): (int, LiltValue) =
    # No semantic meaning, exists only to make code terser
    return (rv.head, rv.lambdaState)

proc `$`(s: seq[inner_ast.Node]): string =
    result = "@["
    var firstItem = true
    for node in s:
        if not firstItem: result &= ", "
        result &= $node
        firstItem = false
    result &= "]"

converter toRuleVal(retVal: (int, string, LiltValue)): RuleVal =
    return RuleVal(
        head: retVal[0],
        lambdaState: retVal[2],
        val: initLiltValue(retVal[1]).some,
    )

converter toRuleVal(retVal: (int, seq[inner_ast.Node], LiltValue)): RuleVal =
    return RuleVal(
        head: retVal[0],
        lambdaState: retVal[2],
        val: initLiltValue(retVal[1]).some,
    )

converter toRuleval(retVal: (int, inner_ast.Node, LiltValue)): RuleVal =
    return RuleVal(
        head: retVal[0],
        lambdaState: retVal[2],
        val: initLiltValue(retVal[1]).some,
    )

converter toRuleVal(retVal: (int, LiltValue)): RuleVal =
    return RuleVal(
        head: retVal[0],
        lambdaState: retVal[1],
        val: none(LiltValue),
    )

converter toRuleVal(retVal: (int, Option[LiltValue], LiltValue)): RuleVal =
    return RuleVal(
        head: retVal[0],
        lambdaState: retVal[2],
        val: retVal[1],
    )

type LiltContext* = TableRef[string, Rule]

const doDebug = false
when not doDebug:
    template debugWrap(rule: Rule, node: ONode): Rule =
        rule

else:
    var debugDepth = 0

    proc debugEcho(msg: string) =
        echo ".   ".repeat(debugDepth) & msg

    proc debugPush(msg: string) =
        debugEcho(msg)
        inc(debugDepth)

    proc debugPop(msg: string) =
        dec(debugDepth)
        debugEcho(msg)

    proc debugWrap(rule: Rule, node: ONode): Rule =
        proc wrappedRule(head: int, text: string, lambdaState: LiltValue): RuleVal =
            const snippetSize = 15
            # Documentation of this line is left as an excersize for the reader:
            let textSnippet = text[max(0, head - snippetSize) .. head - 1] & "[" & text[head] & "]" & text[head + 1 .. min(text.len, head + snippetSize)]
            debugPush("Attempting to match `$1` to `$2`" % [strutils.escape(textSnippet, prefix="", suffix=""), node.toLilt])
            try:
                result = rule(head, text, lambdaState)
            except RuleError as e:
                debugPop("Failed: " & e.msg)
                raise e
            assert result.kind == node.returnType
            debugPop("Success, head now: " & $result.head)
            return result
        return wrappedRule


type WrongTypeError = object of Exception

method translate(node: ONode, context: LiltContext): Rule {.base.} =
    raise newException(WrongTypeError, "Cannot translate node $1" % $node)

method translate(re: Reference, context: LiltContext): Rule =
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        # Creating new lambda states is handled in the translate(Lambda) code
        if re.id in context:
            return context[re.id](head, text, lambdaState)
        else:
            return liltBuiltins[re.id].rule(head, text, lambdaState)

    return debugWrap(rule, re)

method translate(lamb: Lambda, context: LiltContext): Rule =
    let innerRule = translate(lamb.body, context)
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        # Each lambda call gets its own context, so create one.
        var returnVal = innerRule(head, text, initLiltValue(lamb.returnType.get))

        # TODO: Should we be checking the type of the body here?
        # Should it be handled earlier?

        if lamb.body of Choice:
            return (returnVal.head, returnVal.val, lambdaState)

        else:
            case lamb.returnType.get:
            of ltText:
                let hasAdj = lamb.scoped.anyIt(it of Adjoinment)
                if hasAdj:
                    # Text found via mutation of lambdaState
                    return (returnVal.head, returnVal.lambdaState.text, lambdaState)
                else:
                    # Text found via return
                    return (returnVal.head, returnVal.val.get.text, lambdaState)
            of ltNode:
                returnVal.lambdaState.node.kind = lamb.returnNodeKind
                return (returnVal.head, returnVal.lambdaState.node, lambdaState)
            of ltList:
                return (returnVal.head, returnVal.lambdaState.list, lambdaState)

    return debugWrap(rule, lamb)

method translate(se: Sequence, context: LiltContext): Rule =
    var rule: proc(head: int, text: string, lambdaState: LiltValue): RuleVal

    assert se.returnType == some(ltText)
    rule = proc(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var head = head
        var lambdaState = lambdaState
        
        var returnText = ""

        for i, node in se.contents:
            let returnVal = translate(node, context)(head, text, lambdaState)
            (head, lambdaState) = returnVal.hls

            if se.contents[i].returnType == some(ltText):
                returnText &= returnVal.val.get.text

        return (head, returnText, lambdaState)

    return debugWrap(rule, se)

method translate(ch: Choice, context: LiltContext): Rule =
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        for node in ch.contents:
            try:
                return translate(node, context)(head, text, lambdaState)
            except RuleError:
                discard
        raise newException(RuleError, "Didn't match any rule.")

    return debugWrap(rule, ch)

method translate(li: Literal, context: LiltContext): Rule =
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var head = head
        for ci in 0 ..< li.text.len:
            if li.text[ci] == text{head}:
                inc(head)
            else:
                raise newException(
                    RuleError,
                    "Code didn't match literal at char $1; expected '$2' but got '$3'." % [
                        $head, $li.text[ci], $text{head}
                    ]
                )
        return (head, li.text, lambdaState)

    return debugWrap(rule, li)

method translate(s: Set, context: LiltContext): Rule =
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        let c = text{head}
        if c in s.charset:
            return (head + 1, $c, lambdaState)
        raise newException(RuleError, "'$1' not in $2." % [$c, $s])

    return debugWrap(rule, s)

method translate(o: Optional, context: LiltContext): Rule =
    let innerRule = translate(o.inner, context)
    var rule: proc(head: int, text: string, lambdaState: LiltValue): RuleVal

    if o.inner.returnType == none(LiltType):
        rule = proc(head: int, text: string, lambdaState: LiltValue): RuleVal =
            return innerRule(head, text, lambdaState).hls

    else:
        rule = proc(head: int, text: string, lambdaState: LiltValue): RuleVal =
            try:
                return innerRule(head, text, lambdaState)
            except RuleError:
                case o.returnType.get:
                of ltList:
                    return (head, newSeq[inner_ast.Node](), lambdaState)
                of ltText:
                    return (head, "", lambdaState)
                else:
                    assert false

    return debugWrap(rule, o)

method translate(op: OnePlus, context: LiltContext): Rule =
    let innerRule = translate(op.inner, context)

    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var head = head
        var lambdaState = lambdaState

        var matchedCount = 0

        var returnNodeList: seq[inner_ast.Node] = @[]
        var returnText = ""

        while true:
            var retVal: RuleVal
            try:
                retVal = innerRule(head, text, lambdaState)
            except RuleError:
                break

            (head, lambdaState) = retVal.hls

            if op.returnType.isSome:
                case op.returnType.get:
                of ltText:
                    returnText &= retVal.val.get.text
                of ltNode:
                    assert false
                of ltList:
                    returnNodeList.add(retVal.val.get.node)

            inc(matchedCount)

        if matchedCount == 0:
            raise newException(RuleError, "Expected text to match at least once.")

        if op.returnType.isNone:
            return (head, lambdaState)

        case op.returnType.get:
        of ltText:
            return (head, returnText, lambdaState)
        of ltNode:
            assert false
        of ltList:
            return (head, returnNodeList, lambdaState)

    return debugWrap(rule, op)

method translate(g: Guard, context: LiltContext): Rule =
    let innerRule = translate(g.inner, context)

    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        try:
            discard innerRule(head, text, lambdaState)
        except RuleError:
            return (head, lambdaState)
        raise newException(RuleError, "Code matched guard inner rule.")

    return debugWrap(rule, g)

method translate(p: outer_ast.Property, context: LiltContext): Rule =
    let innerRule = translate(p.inner, context)

    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var lambdaState = lambdaState
        var head = head

        let returnVal = innerRule(head, text, lambdaState)
        (head, lambdaState) = returnVal.hls
        lambdaState.node.properties[p.propName] = returnVal.val.get

        return (head, lambdaState)
    
    return debugWrap(rule, p)

method translate(adj: Adjoinment, context: LiltContext): Rule =
    let innerRule = translate(adj.inner, context)

    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var lambdaState = lambdaState
        let returnVal = innerRule(head, text, lambdaState)

        assert adj.inner.returnType == some(ltText)
        lambdaState.text &= returnVal.val.get.text

        return (returnVal.head, lambdaState)

    return debugWrap(rule, adj)


method translate(e: Extension, context: LiltContext): Rule =
    let innerRule = translate(e.inner, context)
    
    proc rule(head: int, text: string, lambdaState: LiltValue): RuleVal =
        var lambdaState = lambdaState
        let returnVal = innerRule(head, text, lambdaState)

        assert e.inner.returnType == some(ltNode)
        lambdaState.list.add(returnVal.val.get.node)

        return (returnVal.head, lambdaState)
   

    return debugWrap(rule, e)

#~# Exposed API #~#

proc toParser(rule: Rule, returnType: LiltType, consumeAll=true): Parser =
    ## If `consumeall` is false, will not raise an error if rule doesn't fully consume code
    if consumeall:
        return proc(text: string): LiltValue =
            let res = rule(0, text, initLiltValue(returnType))
            if res.head != text.len:
                raise newException(ValueError, "Unconsumed code leftover")  # TODO better exception??
            return res.val.get
    else:
        return proc(text: string): LiltValue =
            return rule(0, text, initLiltValue(returnType)).val.get

proc programToContext*(ast: Program, consumeAll=true): Table[string, Parser] =
    ## Translates a (preprocessed) program to a table of definitions
    var liltContext = newTable[string, Rule]()
    var resultTable = initTable[string, Parser]()
    for definition in ast.definitions.mapIt(it.Definition):
        let id = definition.id
        let rule = translate(definition.body, liltContext)
        liltContext[id] = rule
        resultTable[id] = toParser(rule, ast.findDefinition(id).returnType.get, consumeAll)
    return resultTable
