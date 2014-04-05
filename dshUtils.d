/*
  The D Shell's Utilities.
  Copyright alphaKAI 2014 http://alpha-kai-net.info
 */

import main;
import std.stdio;
import std.file,
       std.format,
       std.regex,
       std.array;

class DshUtils{
  static DshCore sharedDshCoreInstance;

  this(DshCore instanceOfDshCore){
    sharedDshCoreInstance = instanceOfDshCore;
  }

  public string writePromptLine(){
    string currentUser     = sharedDshCoreInstance.user;
    string hostname        = sharedDshCoreInstance.hostname;
    string currentDirctory = (){
      string tmp     = getcwd();
      string homeDir = sharedDshCoreInstance.homeDir ~ "/";
      if(tmp.match(regex(homeDir)))
        tmp = tmp.replace(regex(homeDir), "~/");
      return tmp;
    }();
    auto prompt = appender!string;

    formattedWrite(prompt, "%s@%s %s %% ", currentUser, hostname,currentDirctory);
    return prompt.data;
  }
}
