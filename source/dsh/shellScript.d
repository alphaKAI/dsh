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

struct EngineProcess {
  bool isKemEvent;
  string commandName;
  string[] arguments;
  string[] inputs;
}

class DSHshellScript {
  private DSHEnvironment env;
  private ExecuteMachine EM;
  private char[char] TokenPairs;
  private char[char] TokenPairsReversed;
  private char[] Quotes;

  this(ExecuteMachine _EM, DSHEnvironment _env) {
    EM  = _EM;
    env = _env;

    registerTokens;
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
}

