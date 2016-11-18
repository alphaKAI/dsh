module dsh.environment;
import std.algorithm.searching,
       std.algorithm.iteration,
       std.string,
       std.range,
       std.regex;

class DSHEnvironment {
  private string[string] env;
  public  string[string] aliases;

  @property string[string] envs() {
    return env;
  }

  public void setEnv(string key, string value) {
    env[key] = value;
  }

  public void deleteEnv(string key) {
    if (env.keys.canFind(key)){
      env.remove(key);
    }
  }

  public string getEnv(string key) {
    return env.keys.canFind(key) ? env[key] : ""; 
  }

  public string replaceEnvs(string line) {
    return 
      line.split.map!(e =>
          (r => r.empty ? e : getEnv(r[0]))(e.matchAll(regex(r"\$\w+")).map!join.array)
        ).join(" ");
  }
}
