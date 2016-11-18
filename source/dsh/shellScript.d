module dsh.shellScript;
import dsh.executeMachine,
       dsh.environment;
import kontainer.stack;
import std.algorithm.iteration,
       std.string,
       std.array,
       std.range,
       std.regex,
       std.stdio,
       std.conv;

import orelang.operator.IOperator,
       orelang.Engine,
       orelang.Value;

struct EngineProcess {
  bool isKemEvent;
  string commandName;
  string[] arguments;
  string[] inputs;
}

class ShellScriptEngine : Engine {
  private char[char] TokenPairs;
  private char[char] TokenPairsReversed;
  private char[] Quotes;

  this() {
    registerTokens;

    super();
  }

  private void registerTokens() {
    TokenPairs = [
      '{' : '}',
      '|' : '|',
      '[' : ']',
      '(' : ')'
    ];
    Quotes = ['\'', '"', '`'];

    foreach (k, v; TokenPairs) {
      TokenPairsReversed[v] = k;
    }
  }

  public bool tokenValidator(string code) {
    Stack!char TokenStack;
    Stack!char QuoteStack;
    bool inQuote;

    foreach (m, line; code.split("\n")) {
      foreach (n, c; line.to!(char[])) {
        foreach (q; Quotes) {
          if (c == q) {
            inQuote = !inQuote;
            QuoteStack.push(q);
            break;
          }
        }

        if (!inQuote) {
          if (c in TokenPairs) {
            TokenStack.push(c);
            continue;
          }

          if (c in TokenPairsReversed) {
            if (TokenStack.empty) {
              writeln("Invalid - at line:", ++m, " column:", ++n);
              return false;
            }

            char t = TokenStack.pop;
            if (TokenPairs[t] != c) {
              writeln("Invalid - at line:", ++m, " column:", ++n);
              writeln("Expected : ", TokenPairs[t], " but given : ", c);
              return false;
            }

            continue;
          }
        }
      }
    }

    bool QuoteValid;

    if (QuoteStack.length % 2 == 0) {
      Stack!char quoteTmp;

      foreach (_; ((QuoteStack.length/2).iota)) {
        quoteTmp.push(QuoteStack.pop);
        if (quoteTmp.pop != QuoteStack.pop) {
          break;
        }
      }

      QuoteValid = true;
    }

    return TokenStack.empty && QuoteValid;
  }

  public void registerEM(ExecuteMachine EM) {
    foreach (event; EM.events) {
      this.defineVariable(event.eventName, new Value(cast(IOperator)(
      new class () IOperator {
        public Value call(Engine engine, Value[] args) {
          string[] sargs = event.eventName ~ args.map!(arg => arg.getString).array;
          string cmd     = sargs.join(" ");

          return new Value(event.behave(sargs, cmd));
        }
      })));
    }
  }
}

