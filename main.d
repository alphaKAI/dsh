/*
   The D Shell.
   This is the UNIX Shell Enviromnent, which is called "D Shell".
   It have Bash like syntax, but this is writteln in D language.
   
   Copyright alphaKAI 2014 http://alpha-kai-net.info
 */

import std.algorithm,
       std.string,
       std.format,
       std.array,
       std.stdio,
       std.conv;

import dshParser;
import dshUtils;

class DshCore{
  // Common Datas
  static string kindOfOS;
  static string user;//Current User Name
  //Errors
  static string[] errors;
  static string latestErrorInformation;

  this(){
    // Checking for exciting OS
    kindOfOS = "Linux";
  }

}

void main(){
  string line;
  DshCore   dc = new DshCore();
  DshParser dp = new DshParser(dc);
  DshUtils  du = new DshUtils(dc);

  while(true){
    line = readln();
    if(line.empty)
      continue;

    with(dp){
      if(afterDo(parser(line) == -1))
        break;
    }
  }
}
