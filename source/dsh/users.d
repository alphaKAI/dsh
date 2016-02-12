module dsh.users;
import dsh.config;
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

alias dsh.config.ElementType ElementType;

class DSHUser {
  private DSHConfig config;
  private int    userLevel;
  private string userName;
  private string originalName;
  private bool   _suMode;
  private string configFilePath;

  this(int level, string name) {
    userLevel      = name == "roor" ? 1 : 0;
    userName       = name;
    originalName   = name;
    _suMode        = false;
    configFilePath = "config/" ~ name ~ ".json";
    config         = new DSHConfig;

    loadUserConfig;
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

  @property bool isRoot() {
    return userLevel == 1;
  }
  
  @property string home() {
    return config.getConfig("home").to!string;
  }

  @property string[string] aliases() {
    string[string] _aliases = string[string].init;
    auto value = (*config.getConfig("aliases").peek!(Variant[string]));

    foreach (k, v; value) {
      _aliases[k] = v.to!string;
    }

    return _aliases;
  }

  public void addAlias(string[string] aliasHash) {
    string[string] _aliases = aliases;
    Variant[string] hash;
    aliases[aliasHash["contracted"]] = aliasHash["expanded"];
    foreach (k, v; aliases) {
      hash[k] = v;
    }

    config.addNewConfig(hash, "aliases", ElementType.OBJECT);
  }

  public void unalias(string aliasName) {
    string[string] _aliases = aliases;
    if (_aliases.keys.canFind(aliasName)) {

      Variant[string] hash;
      _aliases.remove(aliasName);

      foreach (k, v; aliases) {
        hash[k] = v;
      }

      config.addNewConfig(hash, "aliases", ElementType.OBJECT);
    }
  }

  @property void saveConfig() {
    JSONValue jvalue;

    foreach (key; ["name", "password", "home"]) {
      jvalue.object[key] = JSONValue(config.getConfig(key).to!string);
    }
    
    jvalue.object["aliases"] = (*(config.getConfig("aliases").peek!(JSONValue[string])));

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
      writeln("The file is located on #{File.expand_path(@configFilePath)}");
      saveConfig;
      writeln("------------------");
    }
  }
}

class DSHUsers {
  private DSHUser[string] _users;
  private DSHUser _currentUser;
  private DSHUser[] prevUsers;
  private bool _nestedLogin;
  private string usersFileDir = "config/";

  this(DSHUser owner = null) {
    if (owner) {
      _users[owner.name] = owner;
      _currentUser      = owner;
    }
    //loadUsers;
  }

  @property bool nestedLogin() {
    return _nestedLogin;
  }

  @property DSHUser currentUser() {
    return _currentUser;
  }

  @property string[] users() {
    return _users.keys;
  }

  @property bool userExists(string userName) {
    return users.canFind(userName);
  }

  public bool addUser(string userName) {
    if (userExists(userName) is false) {
      _users[userName] = new DSHUser(0, userName);
      writeln("[adding user success] : User name " ~ userName);

      return true;
    } else {
      writeln("[adding user failure] : User name " ~ userName ~ " is alerady exists.");
      return false;
    }
  }

  public bool removeUser(string userName) {
    if (userExists(userName) is true) {
      write("Are you sure to delete " ~ userName ~ "? [Y/N");

      if ((input => input == "y" || input == "Y")(readln.chomp)) {
        if (_users[userName].deleteUser) {
          _users.remove(userName);

          return true;
        }
      }
    }

    return false;
  }

  public bool login(string userName) {
    if (userExists(userName) is false) {
      writeln("Doesn't exist such a user - " ~ userName);

      return false;
    } else {
      if (_users[userName].auth("Please input password for #{userName}")) {
        prevUsers ~= currentUser;
        _nestedLogin = true;
        _currentUser = new DSHUser(0, userName);
        _users[currentUser.name] = currentUser;

        return true;
      } else {
        writeln("[failed to login] : authorization failed");

        return false;
      }
    }
  }

  public void logout() {
    _currentUser = prevUsers[$ - 1];
    prevUsers.popBack();

    if (prevUsers.empty) {
      _nestedLogin = true;
    }
  }

  public bool exit() {
    if (currentUser.exit is true) {
      return true;
    } else if (nestedLogin is true) {
      logout;
    }
    return false;
  }

  private void loadUsers() {
    foreach(e; dirEntries(usersFileDir, SpanMode.depth).filter!(f => f.name.endsWith(".json"))) {
       string userName  = std.path.baseName(e, ".json");
       _users[userName] = new DSHUser(0, userName);
    }
  }
}
