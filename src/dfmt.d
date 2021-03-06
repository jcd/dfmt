/*******************************************************************************
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 * SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 * FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 ******************************************************************************/

module dfmt;

import std.stdio;

import std.d.lexer;
import std.d.parser;
import std.d.formatter;
import std.d.ast;
import std.array;

immutable USAGE = "usage: %s [--inplace] [<path>...]
Formats D code.

      --inplace  change file in-place instead of outputing to stdout
                 (implicit in case of multiple files)
  -h, --help     display this help and exit
";

version (NoMain)
{ } 
else
int main(string[] args)
{
    import std.getopt;

    bool inplace = false;
    bool show_usage = false;
    getopt(args,
      "help|h", &show_usage,
      "inplace", &inplace);
    if (show_usage)
    {
        import std.path: baseName;
        writef(USAGE, baseName(args[0]));
        return 0;
    }
    File output = stdout;
    ubyte[] buffer;
    args.popFront();
    if (args.length == 0)
    {
        ubyte[4096] inputBuffer;
        ubyte[] b;
        while (true)
        {
            b = stdin.rawRead(inputBuffer);
            if (b.length)
                buffer ~= b;
            else
                break;
        }
        format("stdin", buffer, output.lockingTextWriter());
    }
    else
    {
        import std.file;
        if (args.length >= 2)
            inplace = true;
        while (args.length > 0)
        {
            const path = args.front;
            args.popFront();
            if (isDir(path))
            {
                inplace = true;
                foreach (string name; dirEntries(path, "*.d", SpanMode.depth))
                {
                    args ~= name;
                }
                continue;
            }
            File f = File(path);
            buffer = new ubyte[](cast(size_t)f.size);
            f.rawRead(buffer);
            if (inplace)
                output = File(path, "w");
            format(path, buffer, output.lockingTextWriter());
        }
    }
    return 0;
}


void format(OutputRange)(string source_desc, ubyte[] buffer, OutputRange output)
{
    LexerConfig config;
    config.stringBehavior = StringBehavior.source;
    config.whitespaceBehavior = WhitespaceBehavior.skip;
    LexerConfig parseConfig;
    parseConfig.stringBehavior = StringBehavior.source;
    parseConfig.whitespaceBehavior = WhitespaceBehavior.skip;
    StringCache cache = StringCache(StringCache.defaultBucketCount);
    ASTInformation astInformation;
    FormatterConfig formatterConfig;
    auto parseTokens = getTokensForParser(buffer, parseConfig, &cache);
    auto mod = parseModule(parseTokens, source_desc);
    auto visitor = new FormatVisitor(&astInformation);
    visitor.visit(mod);
    astInformation.cleanup();
    auto tokens = byToken(buffer, config, &cache).array();
    auto tokenFormatter = TokenFormatter!OutputRange(tokens, output, &astInformation,
        &formatterConfig);
    tokenFormatter.format();
}

struct TokenFormatter(OutputRange)
{
    this(const(Token)[] tokens, OutputRange output, ASTInformation* astInformation,
        FormatterConfig* config)
    {
        this.tokens = tokens;
        this.output = output;
        this.astInformation = astInformation;
        this.config = config;
    }

    void format()
    {
        while (index < tokens.length)
            formatStep();
    }

    invariant
    {
        assert (indentLevel >= 0);
    }

private:

    void formatStep()
    {
        import std.range:assumeSorted;

        assert (index < tokens.length);
        if (current.type == tok!"comment")
        {
            const i = index;
            if (i > 0)
            {
                if (tokens[i-1].line < tokens[i].line)
                {
                    if (tokens[i-1].type != tok!"comment"
                        && tokens[i-1].type != tok!"{")
                        newline();
                }
                else
                    write(" ");
            }
            writeToken();
            if (i >= tokens.length-1)
                newline();
            else if (tokens[i+1].line > tokens[i].line)
                newline();
            else if (tokens[i+1].type != tok!"{")
                write(" ");
        }
        else if (isStringLiteral(current.type) || isNumberLiteral(current.type)
            || current.type == tok!"characterLiteral")
        {
            writeToken();
        }
        else if (current.type == tok!"module" || current.type == tok!"import")
        {
            auto t = current.type;
            writeToken();
            write(" ");
            while (index < tokens.length)
            {
                if (current.type == tok!";")
                {
                    writeToken();
                    tempIndent = 0;
                    if (!(t == tok!"import" && current.type == tok!"import"))
                        write("\n");
                    newline();
                    break;
                }
                else if (current.type == tok!",")
                {
                    // compute length until next , or ;
                    int length_of_next_chunk = INVALID_TOKEN_LENGTH;
                    for (size_t i=index+1; i<tokens.length; i++)
                    {
                        if (tokens[i].type == tok!"," || tokens[i].type == tok!";")
                            break;
                        const len = tokenLength(i);
                        assert (len >= 0);
                        length_of_next_chunk += len;
                    }
                    assert (length_of_next_chunk > 0);
                    writeToken();
                    if (currentLineLength+1+length_of_next_chunk >= config.columnSoftLimit)
                    {
                        pushIndent();
                        newline();
                    }
                    else
                        write(" ");
                }
                else
                    formatStep();
            }
        }
        else if (current.type == tok!"return")
        {
            writeToken();
            write(" ");
        }
        else if (current.type == tok!"switch")
            formatSwitch();
        else if (current.type == tok!"for" || current.type == tok!"foreach"
            || current.type == tok!"foreach_reverse" || current.type == tok!"while"
            || current.type == tok!"if")
        {
            currentLineLength += currentTokenLength() + 1;
            writeToken();
            write(" ");
            writeParens(false);
            if (current.type != tok!"{" && current.type != tok!";")
            {
                pushIndent();
                newline();
            }
        }
        else if (isKeyword(current.type))
        {
            switch (current.type)
            {
            case tok!"default":
            case tok!"cast":
                writeToken();
                break;
            case tok!"mixin":
                writeToken();
                write(" ");
                break;
            default:
                if (index + 1 < tokens.length)
                {
                    auto next = tokens[index + 1];
                    if (next.type == tok!";" || next.type == tok!"("
                        || next.type == tok!")" || next.type == tok!","
                        || next.type == tok!"{" || next.type == tok!".")
                    {
                        writeToken();
                    }
                    else
                    {
                        writeToken();
                        write(" ");
                    }
                }
                else
                    writeToken();
                break;
            }
        }
        else if (isBasicType(current.type))
        {
            writeToken();
            if (current.type == tok!"identifier" || isKeyword(current.type))
                write(" ");
        }
        else if (isOperator(current.type))
        {
            switch (current.type)
            {
            case tok!"*":
                if (!assumeSorted(astInformation.spaceAfterLocations)
                    .equalRange(current.index).empty)
                {
                    writeToken();
                    write(" ");
                    break;
                }
                goto case;
            case tok!"~":
            case tok!"&":
            case tok!"+":
            case tok!"-":
                if (!assumeSorted(astInformation.unaryLocations)
                    .equalRange(current.index).empty)
                {
                    writeToken();
                    break;
                }
                goto binary;
            case tok!"(":
                writeParens(true);
                break;
            case tok!":":
                if (!assumeSorted(astInformation.ternaryColonLocations)
                    .equalRange(current.index).empty)
                {
                    write(" ");
                    writeToken();
                    write(" ");
                }
                else
                    writeToken();
                break;
            case tok!"@":
            case tok!"!":
            case tok!"...":
            case tok!"[":
            case tok!"++":
            case tok!"--":
            case tok!"$":
                writeToken();
                break;
            case tok!"]":
                writeToken();
                if (current.type == tok!"identifier")
                    write(" ");
                break;
            case tok!";":
                tempIndent = 0;
                writeToken();
                if (current.type != tok!"comment")
                    newline();
                break;
            case tok!"{":
                writeBraces();
                break;
            case tok!".":
                if (currentLineLength + nextTokenLength() >= config.columnSoftLimit)
                {
                    pushIndent();
                    newline();
                    writeToken();
                }
                else
                    writeToken();
                break;
            case tok!",":
                if (currentLineLength + nextTokenLength() >= config.columnSoftLimit)
                {
                    pushIndent();
                    writeToken();
                    newline();
                }
                else
                {
                    writeToken();
                    write(" ");
                }
                break;
            case tok!"^^":
            case tok!"^=":
            case tok!"^":
            case tok!"~=":
            case tok!"<<=":
            case tok!"<<":
            case tok!"<=":
            case tok!"<>=":
            case tok!"<>":
            case tok!"<":
            case tok!"==":
            case tok!"=>":
            case tok!"=":
            case tok!">=":
            case tok!">>=":
            case tok!">>>=":
            case tok!">>>":
            case tok!">>":
            case tok!">":
            case tok!"|=":
            case tok!"||":
            case tok!"|":
            case tok!"-=":
            case tok!"!<=":
            case tok!"!<>=":
            case tok!"!<>":
            case tok!"!<":
            case tok!"!=":
            case tok!"!>=":
            case tok!"!>":
            case tok!"?":
            case tok!"/=":
            case tok!"/":
            case tok!"..":
            case tok!"*=":
            case tok!"&=":
            case tok!"&&":
            case tok!"%=":
            case tok!"%":
            case tok!"+=":
            binary:
                if (currentLineLength + nextTokenLength() >= config.columnSoftLimit)
                {
                    pushIndent();
                    newline();
                }
                else
                    write(" ");
                writeToken();
                write(" ");
                break;
            default:
                assert (false, str(current.type));
            }
        }
        else if (current.type == tok!"identifier")
        {
            writeToken();
            if (current.type == tok!"identifier" || isKeyword(current.type)
                || current.type == tok!"@")
                write(" ");
        }
        else
            assert (false, str(current.type));
    }

	/// Pushes a temporary indent level
    void pushIndent()
    {
        if (tempIndent == 0)
            tempIndent++;
    }

	/// Pops a temporary indent level
    void popIndent()
    {
        if (tempIndent > 0)
            tempIndent--;
    }

	/// Writes balanced braces
    void writeBraces()
    {
        import std.range : assumeSorted;
        int depth = 0;
        do
        {
            if (current.type == tok!"{")
            {
                depth++;
                if (config.braceStyle == BraceStyle.otbs)
                {
                    write(" ");
                    write("{");
                }
                else
                {
                    newline();
                    write("{");
                }
                indentLevel++;
                index++;
                newline();
            }
            else if (current.type == tok!"}")
            {
				// Silly hack to format enums better.
                if (peekBackIs(tok!"identifier"))
                    newline();
                write("}");
                depth--;
                if (index < tokens.length-1 &&
                    assumeSorted(astInformation.doubleNewlineLocations)
                    .equalRange(tokens[index].index).length)
                {
                    output.put("\n");
                }
                if (config.braceStyle == BraceStyle.otbs)
                {
                    index++;
                    if (index < tokens.length && current.type == tok!"else")
                        write(" ");
                    else
                    {
                        if (peekIs(tok!"case") || peekIs(tok!"default"))
                            indentLevel--;
                        newline();
                    }
                }
                else
                {
                    index++;
                    if (peekIs(tok!"case") || peekIs(tok!"default"))
                        indentLevel--;
                    newline();
                }
            }
            else
                formatStep();
        }
        while (index < tokens.length && depth > 0);
        popIndent();
    }

    void writeParens(bool space_afterwards)
    in
    {
        assert (current.type == tok!"(", str(current.type));
    }
    body
    {
        immutable t = tempIndent;
        int depth = 0;
        do
        {
            if (current.type == tok!";")
            {
                write("; ");
                currentLineLength += 2;
                index++;
                continue;
            }
            else if (current.type == tok!"(")
            {
                writeToken();
                depth++;
                continue;
            }
            else if (current.type == tok!")")
            {
                if (peekIs(tok!"identifier") || (index + 1 < tokens.length
                    && isKeyword(tokens[index + 1].type)))
                {
                    writeToken();
                    if (space_afterwards)
                      write(" ");
                }
                else
                    writeToken();
                depth--;
            }
            else
                formatStep();
        }
        while (index < tokens.length && depth > 0);
        popIndent();
        tempIndent = t;
    }

    bool peekIsLabel()
    {
        return peekIs(tok!"identifier") && peek2Is(tok!":");
    }

    void formatSwitch()
    {
        immutable l = indentLevel;
        writeToken(); // switch
        write(" ");
        writeParens(true);
        if (current.type != tok!"{")
            return;
        if (config.braceStyle == BraceStyle.otbs)
            write(" ");
        else
            newline();
        writeToken();
        newline();
        while (index < tokens.length)
        {
            if (current.type == tok!"case")
            {
                writeToken();
                write(" ");
            }
            else if (current.type == tok!":")
            {
                if (peekIs(tok!".."))
                {
                    writeToken();
                    write(" ");
                    writeToken();
                    write(" ");
                }
                else
                {
                    if (!(peekIs(tok!"case") || peekIs(tok!"default") || peekIsLabel()))
                        indentLevel++;
                    formatStep();
                    newline();
                }
            }
            else
            {
                assert (current.type != tok!"}");
                if (peekIs(tok!"case") || peekIs(tok!"default") || peekIsLabel())
                {
                    indentLevel = l;
                    formatStep();
                }
                else
                {
                    formatStep();
                    if (current.type == tok!"}")
                        break;
                }
            }
        }
        indentLevel = l;
        assert (current.type == tok!"}");
        writeToken();
        newline();
    }

    int tokenLength(size_t i) pure @safe @nogc
    {
        import std.algorithm : countUntil;
        assert (i+1 <= tokens.length);
        switch (tokens[i].type)
        {
        case tok!"identifier":
        case tok!"stringLiteral":
        case tok!"wstringLiteral":
        case tok!"dstringLiteral":
            auto c = cast(int) tokens[i].text.countUntil('\n');
            if (c == -1)
                return cast(int) tokens[i].text.length;
        mixin (generateFixedLengthCases());
        default: return INVALID_TOKEN_LENGTH;
        }
    }

    int currentTokenLength() pure @safe @nogc
    {
        return tokenLength(index);
    }

    int nextTokenLength() pure @safe @nogc
    {
        if (index + 1 >= tokens.length)
            return INVALID_TOKEN_LENGTH;
        return tokenLength(index + 1);
    }

    ref current() const @property
    in
    {
        assert (index < tokens.length);
    }
    body
    {
        return tokens[index];
    }

    bool peekBackIs(IdType tokenType)
    {
        return (index >= 1) && tokens[index - 1].type == tokenType;
    }

    bool peekImplementation(IdType tokenType, size_t n)
    {
        auto i = index + n;
        while (i < tokens.length && tokens[i].type == tok!"comment")
            i++;
        return i < tokens.length && tokens[i].type == tokenType;
    }

    bool peek2Is(IdType tokenType)
    {
        return peekImplementation(tokenType, 2);
    }

    bool peekIs(IdType tokenType)
    {
        return peekImplementation(tokenType, 1);
    }

    void newline()
    {
        output.put("\n");
        currentLineLength = 0;
        if (index < tokens.length)
        {
            if (current.type == tok!"}")
                indentLevel--;
            indent();
        }
    }

    void write(string str)
    {
        currentLineLength += str.length;
        output.put(str);
    }

    void writeToken()
    {
        currentLineLength += currentTokenLength();
        if (current.text is null)
            output.put(str(current.type));
        else
            output.put(current.text);
        index++;
    }

    void indent()
    {
        import std.range : repeat, take;
        if (config.useTabs)
            foreach (i; 0 .. indentLevel + tempIndent)
            {
                currentLineLength += config.tabSize;
                output.put("\t");
            }
        else
            foreach (i; 0 .. indentLevel + tempIndent)
                foreach (j; 0 .. config.indentSize)
                {
                    output.put(" ");
                    currentLineLength++;
                }
    }

    /// Length of an invalid token
    enum int INVALID_TOKEN_LENGTH = -1;

    /// Current index into the tokens array
    size_t index;

    /// Current indent level
    int indentLevel;

    /// Current temproray indententation level;
    int tempIndent;

    /// Length of the current line (so far)
    uint currentLineLength = 0;

    /// Output to write output to
    OutputRange output;

    /// Tokens being formatted
    const(Token)[] tokens;

    /// Information about the AST
    ASTInformation* astInformation;

    /// Configuration
    FormatterConfig* config;
}

/// The only good brace styles
enum BraceStyle
{
    allman,
    otbs
}

/// Configuration options for formatting
struct FormatterConfig
{
    /// Number of spaces used for indentation
    uint indentSize = 4;

    /// Use tabs or spaces
    bool useTabs = false;

    /// Size of a tab character
    uint tabSize = 8;

    /// Soft line wrap limit
    uint columnSoftLimit = 80;

    /// Hard line wrap limit
    uint columnHardLimit = 120;

    /// Use the One True Brace Style
    BraceStyle braceStyle = BraceStyle.allman;
}

///
struct ASTInformation
{
    /// Sorts the arrays so that binary search will work on them
    void cleanup()
    {
        import std.algorithm : sort;
        sort(doubleNewlineLocations);
        sort(spaceAfterLocations);
        sort(unaryLocations);
    }

    /// Locations of end braces for struct bodies
    size_t[] doubleNewlineLocations;

    /// Locations of tokens where a space is needed (such as the '*' in a type)
    size_t[] spaceAfterLocations;

    /// Locations of unary operators
    size_t[] unaryLocations;

    /// Locations of ':' operators in ternary expressions
    size_t[] ternaryColonLocations;
}

/// Collects information from the AST that is useful for the formatter
final class FormatVisitor : ASTVisitor
{
    ///
    this(ASTInformation* astInformation)
    {
        this.astInformation = astInformation;
    }

    override void visit(const FunctionBody functionBody)
    {
        if (functionBody.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.blockStatement.endLocation;
        if (functionBody.inStatement !is null && functionBody.inStatement.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.inStatement.blockStatement.endLocation;
        if (functionBody.outStatement !is null && functionBody.outStatement.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.outStatement.blockStatement.endLocation;
        if (functionBody.bodyStatement !is null && functionBody.bodyStatement.blockStatement !is null)
            astInformation.doubleNewlineLocations ~= functionBody.bodyStatement.blockStatement.endLocation;
        functionBody.accept(this);
    }

    override void visit(const EnumBody enumBody)
    {
        astInformation.doubleNewlineLocations ~= enumBody.endLocation;
        enumBody.accept(this);
    }

    override void visit(const Unittest unittest_)
    {
        astInformation.doubleNewlineLocations ~= unittest_.blockStatement.endLocation;
        unittest_.accept(this);
    }

    override void visit(const Invariant invariant_)
    {
        astInformation.doubleNewlineLocations ~= invariant_.blockStatement.endLocation;
        invariant_.accept(this);
    }

    override void visit(const StructBody structBody)
    {
        astInformation.doubleNewlineLocations ~= structBody.endLocation;
        structBody.accept(this);
    }

    override void visit(const TemplateDeclaration templateDeclaration)
    {
        astInformation.doubleNewlineLocations ~= templateDeclaration.endLocation;
        templateDeclaration.accept(this);
    }

    override void visit(const TypeSuffix typeSuffix)
    {
        if (typeSuffix.star.type != tok!"")
            astInformation.spaceAfterLocations ~= typeSuffix.star.index;
        typeSuffix.accept(this);
    }

    override void visit(const UnaryExpression unary)
    {
        if (unary.prefix.type == tok!"~" || unary.prefix.type == tok!"&"
            || unary.prefix.type == tok!"*" || unary.prefix.type == tok!"+"
            || unary.prefix.type == tok!"-")
        {
            astInformation.unaryLocations ~= unary.prefix.index;
        }
        unary.accept(this);
    }

    override void visit(const TernaryExpression ternary)
    {
        if (ternary.colon.type != tok!"")
            astInformation.ternaryColonLocations ~= ternary.colon.index;
        ternary.accept(this);
    }

private:
    ASTInformation* astInformation;
    alias visit = ASTVisitor.visit;
}

string generateFixedLengthCases()
{
    import std.algorithm:map;
    import std.string:format;

    string[] fixedLengthTokens = [
    "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool",
    "break", "byte", "case", "cast", "catch", "cdouble", "cent", "cfloat",
    "char", "class", "const", "continue", "creal", "dchar", "debug", "default",
    "delegate", "delete", "deprecated", "do", "double", "else", "enum",
    "export", "extern", "false", "final", "finally", "float", "for", "foreach",
    "foreach_reverse", "function", "goto", "idouble", "if", "ifloat",
    "immutable", "import", "in", "inout", "int", "interface", "invariant",
    "ireal", "is", "lazy", "long", "macro", "mixin", "module", "new", "nothrow",
    "null", "out", "override", "package", "pragma", "private", "protected",
    "public", "pure", "real", "ref", "return", "scope", "shared", "short",
    "static", "struct", "super", "switch", "synchronized", "template", "this",
    "throw", "true", "try", "typedef", "typeid", "typeof", "ubyte", "ucent",
    "uint", "ulong", "union", "unittest", "ushort", "version", "void",
    "volatile", "wchar", "while", "with", "__DATE__", "__EOF__", "__FILE__",
    "__FUNCTION__", "__gshared", "__LINE__", "__MODULE__", "__parameters",
    "__PRETTY_FUNCTION__", "__TIME__", "__TIMESTAMP__", "__traits", "__vector",
    "__VENDOR__", "__VERSION__", ",", ".", "..", "...", "/", "/=", "!", "!<",
    "!<=", "!<>", "!<>=", "!=", "!>", "!>=", "$", "%", "%=", "&", "&&", "&=",
    "(", ")", "*", "*=", "+", "++", "+=", "-", "--", "-=", ":", ";", "<", "<<",
    "<<=", "<=", "<>", "<>=", "=", "==", "=>", ">", ">=", ">>", ">>=", ">>>",
    ">>>=", "?", "@", "[", "]", "^", "^=", "^^", "^^=", "{", "|", "|=", "||",
    "}", "~", "~="
    ];

    return fixedLengthTokens.map!(a => format(`case tok!"%s": return %d;`, a, a.length)).join("\n\t");
}
