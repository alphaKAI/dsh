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
  private string[string] blockTokenPairs;
  private string[string] blockTokenPairsReversed;
  private string[string] tokenPairs;
  private string[string] tokenPairsReversed;
  public Stack2!string tokenStack;
  public Stack2!string blockTokenStack;

  this(mrb_state* newMrb, ExecuteMachine _EM, DSHEnvironment _env) {
    EM  = _EM;
    env = _env;
    mrb = newMrb;

    registerTokens;

/*    tokenStack.init;
    tokenStack.autoExtend = false;
    blockTokenStack.init;
    blockTokenStack.autoExtend = false;*/
  }

  private void registerTokens() {
    blockTokenPairs = [
      "module" : "end",
      "class"  : "end",
      "def"    : "end",
      "do"     : "end",
      "{"      :"}"
    ];
    
    foreach (k, v; blockTokenPairs) {
      blockTokenPairsReversed[v] = k;
    }
    
    tokenPairs = [
      "|" : "|",
      "[" : "]",
      "(" : ")",
      "\'" : "\'",
      "\"" : "\""
    ];

    foreach (k, v; tokenPairs) {
      tokenPairsReversed[v] = k;
    }
  }
  
  public bool syntaxValidator(string code) {
    foreach (c; code.split("").filter!(e => e != "\"")) {
      foreach (tk; tokenPairs.keys) {
        if (tk == c) {
          tokenStack.push(tk);
          continue;
        }
      }

      foreach (b, e; tokenPairs) {
        if (c == e) {
          auto t = tokenStack.pop;

          if (t != b) {
            return false;
          }
        }
      }
    }

    foreach (splitter; ["", " "]) {
      foreach (c; code.split(splitter)) {
        foreach (tk; blockTokenPairs) {
          if (tk == c) {
            blockTokenStack.push(tk);
            continue;
          }
        }

        foreach (b, e; blockTokenPairs) {
          if (c == e) {
            if (blockTokenStack.empty) {
              return true;
            }

            auto t = blockTokenStack.pop;
            if (blockTokenPairs[t] != c) {
              return false;
            } else {
              return true;
            }
          }
        }
      }
    }

    return true;
  }

}

