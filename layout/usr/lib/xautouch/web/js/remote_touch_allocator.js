(function (global) {
  var MIN_FINGER = 1;
  var MAX_FINGER = 28;

  function freezeIfPossible(value) {
    if (typeof Object.freeze === 'function') {
      return Object.freeze(value);
    }
    return value;
  }

  function createAllocator() {
    var contacts = {};

    function forEachContact(iteratee) {
      var key;
      for (key in contacts) {
        if (Object.prototype.hasOwnProperty.call(contacts, key)) {
          iteratee(key, contacts[key]);
        }
      }
    }

    function entries() {
      var list = [];
      forEachContact(function (key, contact) {
        list.push([key, contact]);
      });
      return list;
    }

    function findNextFinger() {
      var used = {};
      var finger;
      forEachContact(function (_, contact) {
        used[contact.finger] = true;
      });
      for (finger = MAX_FINGER; finger >= MIN_FINGER; finger -= 1) {
        if (!used[finger]) {
          return finger;
        }
      }
      return null;
    }

    return {
      size: function () {
        return entries().length;
      },
      get: function (contactKey) {
        return contacts[contactKey];
      },
      entries: entries,
      acquire: function (contactKey, data) {
        var existing = contacts[contactKey];
        var finger;
        if (existing) {
          return existing;
        }
        finger = findNextFinger();
        if (finger === null) {
          return null;
        }
        existing = {
          finger: finger,
          data: data
        };
        contacts[contactKey] = existing;
        return existing;
      },
      update: function (contactKey, data) {
        var existing = contacts[contactKey];
        if (!existing) {
          return undefined;
        }
        existing.data = data;
        return existing;
      },
      release: function (contactKey) {
        var existing = contacts[contactKey];
        if (!existing) {
          return undefined;
        }
        delete contacts[contactKey];
        return existing;
      },
      clear: function () {
        var snapshot = entries();
        contacts = {};
        return snapshot;
      }
    };
  }

  global.XXTRemoteTouchAllocator = {
    MIN_FINGER: MIN_FINGER,
    MAX_FINGER: MAX_FINGER,
    createAllocator: createAllocator,
    LIMITS: freezeIfPossible({
      minFinger: MIN_FINGER,
      maxFinger: MAX_FINGER
    })
  };
})(window);
