module dsh.user;
import dsh.executeMachine,
       dsh.environment,
       dsh.shellScript,
       dsh.config;
import std.algorithm.searching,
       std.algorithm.iteration,
       std.digest.sha,
       std.process,
       std.variant,
       std.string,
       std.array,
       std.range,
       std.stdio,
       std.conv,
       std.file,
       std.json,
       std.path;
import orelang.Interpreter,
       orelang.Value;

private alias dsh.config.ElementType ElementType;
class DSHUser {
  private DSHConfig config;
  private int    userLevel;
  private string userName;
  private string originalName;
  private bool   _suMode;
  private string configFilePath;
  private DSHEnvironment _env;
  private Interpreter itpr;

  this(int level, string name) {
    userLevel      = name == "root" ? 1 : 0;
    userName       = name;
    originalName   = name;
    _suMode        = false;
    configFilePath = "config/" ~ name ~ ".json";
    config         = new DSHConfig;
    _env           = new DSHEnvironment;
    itpr           = new Interpreter(new ShellScriptEngine);
  }

  public void init() { 
    foreach (command; dirEntries("commands", SpanMode.depth).filter!(f => f.name.endsWith("ore"))) {
      itpr.executer(readText(command));
    }

    loadUserConfig;
  }

  public auto executeScript(string buffer) {
    return itpr.executer(buffer);
  }

  public void registerEM(ExecuteMachine EM) {
    this.peekEngine.registerEM(EM);
  }

  public ShellScriptEngine peekEngine() {
    return cast(ShellScriptEngine)this.itpr.peekEngine;
  }

  public bool auth(string message = string.init) {
    if (!message.empty) {
      writeln(message);
    }
    
    writeln("Password: =>");
    string input = readln.chomp;
    writeln;
    
    return cast(string)digest!SHA256(input).toHexString == config.getConfig("password").to!string;
  }

  @property DSHEnvironment env() {
    return _env;
  }

  @property bool isRoot() {
    return userLevel == 1;
  }
  
  @property string home() {
    return config.getConfig("home").to!string;
  }

  @property string[string] aliases() {
    return _env.aliases;
  }

  public void addAlias(string _new, string _frm) {
    _env.aliases[_new] = _frm;

    config.addNewConfig(_env.aliases, "aliases", ElementType.OBJECT);
  }

  public void unalias(string aliasName) {
    if (_env.aliases.keys.canFind(aliasName)) {
      _env.aliases.remove(aliasName);
      config.addNewConfig(_env.aliases, "aliases", ElementType.OBJECT);
    }
  }

  @property void saveConfig() {
    JSONValue jvalue = ["name":name];

    foreach (key; ["password", "home"]) {
      jvalue.object[key] = JSONValue(config.getConfig(key).to!string);
    }

    jvalue.object["aliases"] = config.getConfig("aliases").get!(string[string]);

    std.file.write(configFilePath, jvalue.toString);
  }

  public bool suMode() {
    bool success;

    // try limit
    foreach (_; 3.iota) {
      if (auth) {
        success = true;
        break;
      }
    }

    if (success is true) {
      userLevel = 1;
      _suMode   = true;
      userName ~= "\x1B[35m[suMode]\x1B[0m";
    }

    return success;
  }

  public bool exit() {
    if (_suMode is true) {
      userLevel = 0;
      _suMode   = false;
      userName  = originalName;

      return false;
    } else {
      return true;
    }
  }

  public bool deleteUser() {
    if (auth("Please input password for " ~ name)) {
      std.file.remove(configFilePath);
      writeln("Your settings file has been removed.");

      return true;
    } else {
      return false;
    }
  }

  @property string name() {
    return userName;
  }

  @property int level() {
    return userLevel;
  }

  private void loadUserConfig() {
    if (exists(configFilePath)) {
      auto parsed = parseJSON(readText(configFilePath));
      foreach (key, value; parsed.object) {
        switch (value.type) {
          case JSON_TYPE.STRING:
            config.addNewConfig(value.str, key, ElementType.STRING);
            break;
          case JSON_TYPE.INTEGER:
            config.addNewConfig(value.integer, key, ElementType.INTEGER);
            break;
          case JSON_TYPE.UINTEGER:
            config.addNewConfig(value.uinteger, key, ElementType.UINTEGER);
            break;
          case JSON_TYPE.FLOAT:
            config.addNewConfig(value.floating, key, ElementType.FLOAT);
            break;
          case JSON_TYPE.ARRAY:
            config.addNewConfig(value.array, key, ElementType.ARRAY);
            break;
          case JSON_TYPE.OBJECT:
            Variant[string] hash;
            foreach (k, v; value.object) {
              hash[k] = v;
            }
            config.addNewConfig(hash, key, ElementType.OBJECT);
            break;
          case JSON_TYPE.NULL:
            config.addNewConfig(null, key, ElementType.NULL);
            break;

          default: break;
        }
      }

      if (exists("config/" ~ name ~ ".ore")) {
        itpr.executer(readText("config/" ~ name ~ ".ore"));

        if (itpr.peekEngine.variableDefined("aliases")) {
          Value[string] hash = itpr.peekEngine.getVariable("aliases").getHashMap;

          foreach (key, value; hash) {
            this.addAlias(key, value.getString);
          }
        }
      }
    } else {
      writeln("------------------");
      writeln("#Initial settings wizard");
      writeln("Your setting file is yet to be created.");

      config.addNewConfig(name, "name", ElementType.STRING);

      writeln("-password-");
      string p1 = "a",
             p2 = "b";
      bool notFirstTime;
      do {
        if (notFirstTime) {
          writeln("Failed to confirm your password.");
          writeln("Please configure again.");
        }

        write("You Password: => ");
        p1 = readln.chomp;
        writeln;

        write("Confirm: => ");
        p2 = readln.chomp;
        writeln;

        notFirstTime =  true;
      } while (p1 != p2);
      
      config.addNewConfig(cast(string)digest!SHA256(p1).toHexString, "password", ElementType.STRING);

      writeln("-HOME Directory-");
      write("Change your home directory(" ~ environment.get("HOME") ~ ")?(Only for KSL2) [Y/N]: ");

      if ((input => input == "y" || input == "Y")(readln.chomp)) {
        write("Please input your new home directory: => ");
        config.addNewConfig(readln.chomp, "home", ElementType.STRING);
      } else {
        config.addNewConfig(environment.get("HOME"), "home", ElementType.STRING);
      }

      config.addNewConfig((string[string]).init, "aliases", ElementType.OBJECT);

      writeln("Your setting file has been created.");
      writeln("You can edit the setting file anytime.");
 
      this.saveConfig;

      writeln("The file is located on ", configFilePath.absolutePath);
      writeln("------------------");
    }
  }
}
