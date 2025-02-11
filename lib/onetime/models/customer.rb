

class Onetime::Customer < Familia::HashKey
  @values = Familia::SortedSet.new name.to_s.downcase.gsub('::', Familia.delim).to_sym, db: 6
  @domains = Familia::HashKey.new name.to_s.downcase.gsub('::', Familia.delim).to_sym, db: 6

  # NOTE: The SafeDump mixin caches the safe_dump_field_map so updating this list
  # with hot reloading in dev mode will not work. You will need to restart the
  # server to see the changes.
  @safe_dump_fields = [
    :custid,
    :role,
    :verified,
    :updated,
    :created,

    {:plan => ->(cust) { cust.load_plan } }, # safe_dump will be called automatically

    # NOTE: The secrets_created incrementer is null until the first secret
    # is created. See CreateSecret for where the incrementer is called.
    #
    {:secrets_created => ->(cust) { cust.secrets_created || 0 } },

    # We use the hash syntax here since `:active?` is not a valid symbol.
    { :active => ->(cust) { cust.active? } }
  ]

  include Onetime::Models::RedisHash
  include Onetime::Models::Passphrase
  include Onetime::Models::SafeDump

  def initialize custid=nil
    @custid = custid || :anon # if we use accessor methods it will sync to redis.

    # WARNING: There's a gnarly bug in the awkward relationship between
    # RedisHash (local lib) and RedisObject (familia gem) where a value
    # can be set to an instance var, the in-memory cache in RedisHash,
    # and/or the persisted value in redis. RedisHash#method_missing
    # allows for calling fields as method names on the object itself;
    # RedisObject (specifically Familia::HashKey in this case), relies
    # on `[]` and `[]=` to access and set values in redis.
    #
    # The problem is that the value set by RedisHash#method_missing
    # is not available to RedisObject (Familia::HashKey) until after
    # the object has been initialized and `super` called in RedisObject.
    # Long story short: we set these two instance vars do that the
    # identifier method can produce a valid identifier string. But,
    # we're relying on CustomDomain.create to duplicate the effort
    # and set the same values in the way that will persist them to
    # redis. Hopefully I do'nt find myself reading this comment in
    # 5 years and wondering why I can't just call `super` man.

    super name, db: 6 # `name` here refers to `RedisHash#name`
  end

  def custid
    @custid || :anon
  end

  def identifier
    @custid
  end

  def contributor?
    self.contributor.to_s == "true"
  end

  def apitoken? guess
    self.apitoken.to_s == guess.to_s
  end

  def regenerate_apitoken
    self.apitoken = [OT.instance, OT.now.to_f, :apikey, custid].gibbler
  end

  def load_plan
    Onetime::Plan.plan(planid) || {:planid => planid, :source => 'parts_unknown'}
  end

  def get_persistent_value sess, n
    (anonymous? ? sess : self)[n]
  end

  def set_persistent_value sess, n, v
    (anonymous? ? sess : self)[n] = v
  end

  def external_identifier
    if anonymous?
      raise OT::Problem, "Anonymous customer has no external identifier"
    end
    elements = [custid]
    @external_identifier ||= elements.gibbler
    @external_identifier
  end

  def anonymous?
    custid.to_s.eql?('anon')
  end

  def obscure_email
    if anonymous?
      'anon'
    else
      OT::Utils.obscure_email(custid)
    end
  end

  def email
    @custid
  end

  def role
    self.get_value(:role) || 'customer'
  end

  def role? guess
    role.to_s.eql?(guess.to_s)
  end

  def verified?
    !anonymous? && verified.to_s.eql?('true')
  end

  def active?
    # We modify the role when destroying so if a customer is verified
    # and has a role of 'customer' then they are active.
    verified? && role?('customer')
  end

  def pending?
    # A customer is considered pending if they are not anonymous, not verified,
    # and have a role of 'customer'. If any one of these conditions is changes
    # then the customer is no longer pending.
    !anonymous? && !verified? && role?('customer')  # we modify the role when destroying
  end

  def load_session
    OT::Session.load sessid unless sessid.to_s.empty?
  end

  def metadata_list
    if @metadata_list.nil?
      el = [prefix, identifier, :metadata]
      el.unshift Familia.apiversion unless Familia.apiversion.nil?
      @metadata_list = Familia::SortedSet.new Familia.join(el), :db => db
    end
    @metadata_list
  end

  def metadata
    metadata_list.revmembers.collect { |key| OT::Metadata.load key }.compact
  end

  def add_metadata obj
    metadata_list.add OT.now.to_i, obj.key
  end

  def custom_domains_list
    if @custom_domains_list.nil?
      el = [prefix, identifier, :custom_domain]
      el.unshift Familia.apiversion unless Familia.apiversion.nil?
      @custom_domains_list = Familia::SortedSet.new Familia.join(el), :db => db
    end
    @custom_domains_list
  end

  def custom_domains
    custom_domains_list.revmembers.collect { |domain| OT::CustomDomain.load domain, self }.compact
  end

  def add_custom_domain obj
    OT.ld "[add_custom_domain] adding #{obj} to #{self}"
    custom_domains_list.add OT.now.to_i, obj[:display_domain] # not the object identifier
  end

  def remove_custom_domain obj
    custom_domains_list.rem obj[:display_domain] # not the object identifier
  end

  def update_passgen_token v
    self['passgen_token'] = v.encrypt(:key => encryption_key)
  end

  def passgen_token
    self['passgen_token'].decrypt(:key => encryption_key) if has_key?(:passgen_token)
  end

  def encryption_key
    OT::Secret.encryption_key OT.global_secret, custid
  end

  def destroy_requested!
    # NOTE: we don't use cust.destroy! here since we want to keep the
    # customer record around for a grace period to take care of any
    # remaining business to do with the account.
    #
    # We do however auto-expire the customer record after
    # the grace period.
    #
    # For example if we need to send a pro-rated refund
    # or if we need to send a notification to the customer
    # to confirm the account deletion.
    self.ttl = 7.days
    self.regenerate_apitoken
    self.passphrase = ''
    self.verified = 'false'
    self.role = 'user_deleted_self'
    save
  end

  def to_s
    # If we can treat familia objects as strings, then passing them as method
    # arguments we don't need to check whether it is_a? RedisObject or not;
    # we can simply call `custid.to_s`. In both cases the result is the unqiue
    # ID of the familia object. Usually that is all we need to maintain the
    # relation records -- we don't actually need the instance of the familia
    # object itself. So there's no need to hydrate the familia object from the
    # unless we need to access the object's attributes (e.g., for logging or
    # debugging purposes or modifying/manipulating the object's attributes).
    #
    # As a pilot, CustomDomain has the equivalent method and comment. See the
    # CustomDomain class methods for usage details.
    identifier.to_s
  end

  module ClassMethods
    attr_reader :values
    def add cust
      self.values.add OT.now.to_i, cust.identifier
    end
    def all
      self.values.revrangeraw(0, -1).collect { |identifier| load(identifier) }
    end
    def recent duration=30.days, epoint=OT.now.to_i
      spoint = OT.now.to_i-duration
      self.values.rangebyscoreraw(spoint, epoint).collect { |identifier| load(identifier) }
    end
    def global
      if @global.nil?
        @global = exists?(:GLOBAL) ? load(:GLOBAL) : create(:GLOBAL)
        @global.secrets_created ||= 0
        @global.secrets_shared  ||= 0
      end
      @global
    end

    def anonymous
      cust = new
    end
    def exists? custid
      cust = new custid
      cust.exists?
    end
    def load custid
      cust = new custid
      cust.exists? ? cust : nil
    end
    def create custid, email=nil
      cust = new custid
      # force the storing of the fields to redis
      cust.custid = custid
      cust.role = 'customer'
      cust.save
      add cust
      cust
    end
  end

  extend ClassMethods
end
