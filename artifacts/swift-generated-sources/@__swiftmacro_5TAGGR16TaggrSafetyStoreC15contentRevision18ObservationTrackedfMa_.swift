{
    @storageRestrictions(initializes: _contentRevision)
    init(initialValue) {
      _contentRevision = initialValue
    }
    get {
      access(keyPath: \.contentRevision)
      return _contentRevision
    }
    set {
      guard shouldNotifyObservers(_contentRevision, newValue) else {
        _contentRevision = newValue
        return
      }
      withMutation(keyPath: \.contentRevision) {
        _contentRevision = newValue
      }
    }
    _modify {
      access(keyPath: \.contentRevision)
      _$observationRegistrar.willSet(self, keyPath: \.contentRevision)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.contentRevision)
      }
      yield &_contentRevision
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:58:38-58:41
