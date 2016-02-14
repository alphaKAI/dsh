module dsh.plugin;
import std.string,
       std.regex,
       std.stdio,
       std.conv;

class Plugin {
  public Regex!char pattern;
  private int runLevel;
  private string name;

  @property void setLevel(int level) {
    runLevel = level;
  }

  void setFunc(string _name, string code) {
  }
  
  bool exec(string args) {
    return true;
  }
}
