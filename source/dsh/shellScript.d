module dsh.shellScript;
import mruby2d;
import dsh.executeMachine,
       dsh.environment,
       dsh.stack;
import std.algorithm.iteration,
       std.string,
       std.regex,
       std.array,
       std.conv;

struct EngineProcess {
  bool isKemEvent;
  string commandName;
  string[] arguments;
  string[] inputs;
}

class DSHshellScript {
  private mrb_state* mrb;
  private DSHEnvironment env;
  private ExecuteMachine EM;
  private char[char] TokenPairs;
  private char[char] TokenPairsReversed;
  private char[] Quotes;

  this(mrb_state* newMrb, ExecuteMachine _EM, DSHEnvironment _env) {
    EM  = _EM;
    env = _env;
    mrb = newMrb;

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

    TokenStack.init;
    TokenStack.autoExtend = false;

    QuoteStack.init;
    QuoteStack.autoExtend = false;

    foreach (c; code.to!(char[])) {
      foreach (q; Quotes) {
        if (c == q) {
          QuoteStack.push(q);
          continue;
        }
      }

      foreach (b, e; TokenPairs) {
        if (c == b) {
          TokenStack.push(c);
          continue;
        }

        if (c == e) {
          if (TokenStack.empty) {
            return false;
          }

          char t = TokenStack.pop;
          if (TokenPairs[t] != c) {
            return false;
          }

          continue;
        }
      }
    }

    bool QuoteValid;

    if (QuoteStack.length % 2 == 0) {
      Stack!char quoteTmp;

      quoteTmp.init;
      quoteTmp.autoExtend = false;

      import std.range;
      foreach (_; ((QuoteStack.length/2).iota)) {
        quoteTmp.push(QuoteStack.pop);
      }

      foreach (_; ((QuoteStack.length/2).iota)) {
        if (quoteTmp.pop != QuoteStack.pop) {
          break;
        }
      }

      QuoteValid = true;
    }

    return (TokenStack.empty && QuoteValid);
  }
}

