/*
  The D Shell's Utilities.
  Copyright alphaKAI 2014 http://alpha-kai-net.info
 */

import main;
import std.stdio;
import std.file;

class DshUtils{
  static DshCore sharedDshCoreInstance;

  this(DshCore instanceOfDshCore){
    sharedDshCoreInstance = instanceOfDshCore;
  }

  public string writePromptLine(){
    string currentUser     = sharedDshCoreInstance.user;
    string currentDirctory = getcwd();


    return "hoge@fuga %";
  }
}
