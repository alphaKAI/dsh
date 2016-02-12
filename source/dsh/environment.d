module dsh.environment;

import std.algorithm.searching,
       std.algorithm.iteration,
       std.string,
       std.range,
       std.regex;

class DSHEnvironment {
  private string[string] DSHEnv;

  @property string[string] envs() {
    return DSHEnv;
  }

  public void setEnv(string key, string value) {
    DSHEnv[key] = value;
  }

  public void deleteEnv(string key) {
    if (DSHEnv.keys.canFind(key)){
      DSHEnv.remove(key);
    }
  }

  public string getEnv(string key) {
    return DSHEnv.keys.canFind(key) ? DSHEnv[key] : ""; 
  }

  public string replaceEnvs(string line) {
    return 
      line.split.map!(e =>
          (r => r.empty ? e : getEnv(r[0]))(e.matchAll(regex(r"\$\w+")).map!join.array)
        ).join(" ");
  }
}
