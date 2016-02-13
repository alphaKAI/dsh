module dsh.plugin;
import mruby2d;
import std.string,
       std.regex,
       std.stdio,
       std.conv;

class Plugin {
  public Regex!char pattern;
  private int runLevel;
  private RProc* proc;
  private mrb_state* mrb;
  private string name;

  this() {
    mrb = mrb_open;
  }

  ~this() {
    mrb_close(mrb);
  }

  @property void setLevel(int level) {
    runLevel = level;
  }

  void setFunc(string _name, string code) {
    name = _name;
    proc = compileByCode(mrb, code.toStringz);

    if (proc == null) {
      writeln("failed to compile - ", name);
      mrb_close(mrb);
      return;
    }

    mrb_run(mrb, proc, mrb_top_self(mrb));
  }

  bool exec(string args) {
    return execMRubyString(mrb, name ~ "(\"" ~ args ~ "\")");
  }
}
