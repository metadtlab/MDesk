/// Invalidates account-owned caches and asynchronous work on every transition.
/// The generation also rejects A -> logout -> A responses from the old login.
class AccountRequestScope {
  String _userName = '';
  String _userPkid = '';
  int _generation = 0;

  int get generation => _generation;

  bool update(String userName, String userPkid) {
    if (_userName == userName && _userPkid == userPkid) return false;
    _userName = userName;
    _userPkid = userPkid;
    _generation++;
    return true;
  }

  bool accepts(int generation, String userName, String userPkid) =>
      userName.isNotEmpty &&
      generation == _generation &&
      userName == _userName &&
      userPkid == _userPkid;
}
