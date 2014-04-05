/**
  The D Shell's Parser.
  Copyright alphaKAI 2014 http://alpha-kai-net.info
*/
import main;
import std.stdio;
import std.regex;

bool DshParserDebug = true;

class DshParser{
  enum DshParserReturn{
    SUCCESS,
    FAILURE,
    ERROR,
    EXIT
  }
  static DshCore sharedDshCoreInstance;

  this(DshCore instanceOfDshCore){
    sharedDshCoreInstance = instanceOfDshCore;
  }

  int parser(string line){
    writeln(line);
    //Parse
    return 0;
  }
  int afterDo(int parserReturn){
    with(DshParserReturn){
      switch(parserReturn){
        case SUCCESS:
          //
          break;
        case FAILURE:
          //
          break;
        case ERROR:
          writeln(sharedDshCoreInstance.latestErrorInformation);
          break;
        case EXIT:
          return -1;
        default:
          break;
      }
    }
    return 0;
  }
}
