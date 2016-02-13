module dsh.users;
import dsh.user;
import std.algorithm.searching,
       std.algorithm.iteration,
       std.process,
       std.string,
       std.range,
       std.stdio,
       std.file;


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
    foreach(e; dirEntries(usersFileDir, SpanMode.shallow).filter!(f => f.name.endsWith(".json"))) {
       string userName  = std.path.baseName(e, ".json");
       _users[userName] = new DSHUser(0, userName);
    }
  }
}
