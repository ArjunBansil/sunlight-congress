class Committees

  # options:
  #   cache: don't redownload the YAML files
  #   congress: congress of Congress, for purpose of caring about
  #     whether we have membership data or not

  def self.run(options = {})
    congress = options[:congress] ? options[:congress].to_i : Utils.current_congress

    # wipe and re-clone the unitedstates legislators repo
    unless options[:cache]
      FileUtils.mkdir_p "data/unitedstates"
      FileUtils.rm_rf "data/unitedstates/congress-legislators"
      unless system "git clone git://github.com/unitedstates/congress-legislators.git data/unitedstates/congress-legislators"
        Report.error self, "Couldn't clone legislator data from unitedstates."
        return false
      end
      puts
    end

    # fresh start
    Committee.delete_all

    puts "Loading in YAML files..." if options[:debug]

    # committees that have ever had a bill referred to them, past and present
    bill_committees = YAML.load open("data/unitedstates/congress-legislators/committees-historical.yaml")

    # all current committees, as built from membership rolls
    current_committees = YAML.load open("data/unitedstates/congress-legislators/committees-current.yaml")

    # all current committee memberships
    memberships = YAML.load open("data/unitedstates/congress-legislators/committee-membership-current.yaml")

    legislator_cache = {}
    bad_committees = []

    # *current* committees for which we lack members
    missing_members = []

    # store committees and subcommittees as peers, *and* nest subcommittees inside their committee
    (bill_committees + current_committees).each do |us_committee|
      committee_id = us_committee['thomas_id']
      puts "[#{committee_id}] Processing..." if options[:debug]

      current = current_committees.include?(us_committee)

      committee = Committee.find_or_initialize_by committee_id: committee_id

      committee.attributes = attributes_for us_committee
      committee[:current] = current

      subcommittees = []
      (us_committee['subcommittees'] || []).each do |us_subcommittee|
        subcommittee_id = us_subcommittee['thomas_id']
        full_id = [committee_id, subcommittee_id].join ""
        puts "[#{committee_id}][#{subcommittee_id}] Processing..." if options[:debug]

        subcommittee = Committee.find_or_initialize_by committee_id: full_id

        # basic attributes
        attributes = attributes_for us_subcommittee, committee
        attributes[:committee_id] = full_id
        subcommittees << attributes
        subcommittee.attributes = attributes
        subcommittee[:current] = current

        subcommittee.save!
      end

      subcommittees = subcommittees.map do |subcommittee|
        [:parent_committee, :parent_committee_id, :subcommittee].each do |field|
          subcommittee.delete field
        end
        subcommittee
      end

      committee.attributes = {subcommittees: subcommittees}

      committee.save!
    end

    # should work for both parent and subcommittees.
    Committee.where(current: true).each do |committee|
      members = memberships_for committee, memberships, legislator_cache, missing_members
      if members
        puts "[#{committee.committee_id}] Saving members..." if options[:debug]
        committee.attributes = members
        committee.save!
      else
        puts "[#{committee.committee_id}] MISSING MEMBERSHIP, SAVING AS EMPTY LIST"
        missing_members << committee.committee_id
        committee.attributes = {
          member_ids: [],
          members: []
        }
        committee.save!
      end
    end

    if bad_committees.any?
      Report.warning self, "Unable to process #{bad_committees.size} committees", bad_committees: bad_committees
    end

    if missing_members.any?
      Report.warning self, "Missing members for #{missing_members.size} current committees", missing_members: missing_members
    end

    count = Committee.where(subcommittee: false).count
    sub_count = Committee.where(subcommittee: true).count
    Report.success self, "Processed #{count} committees and #{sub_count} subcommittees"
  end

  def self.attributes_for(us_committee, parent_committee = nil)
    attributes = {
      name: us_committee['name']
    }

    # present only for current committees
    ['url', 'phone'].each do |field|
      if us_committee.has_key?(field)
        attributes[field.to_sym] = us_committee[field]
      end
    end

    if (us_committee['type'] == 'house') and us_committee['address']
      attributes[:office] = us_committee['address'].split("; ").first
    end

    if parent_committee
      attributes[:chamber] = parent_committee[:chamber]
      attributes[:subcommittee] = true
      attributes[:parent_committee_id] = parent_committee[:committee_id]
      attributes[:parent_committee] = {}
      Committee.basic_fields.reject {|f| ["subcommittee", "parent_committee_id"].include?(f.to_s)}.each do |field|
        attributes[:parent_committee][field] = parent_committee[field]
      end
    else
      attributes[:chamber] = us_committee['type']
      attributes[:subcommittee] = false
    end

    attributes
  end

  # could be either a committee or subcommittee, this function should be blind
  def self.memberships_for(committee, memberships, legislator_cache, missing_members)
    committee_id = committee.committee_id

    unless memberships[committee_id]
      return nil
    end

    members = memberships[committee_id].map do |member|

      unless legislator_cache[member['bioguide']]
        legislator = Legislator.where(bioguide_id: member['bioguide']).first
        if legislator
          legislator_cache[member['bioguide']] = Utils.legislator_for(legislator)
        else
          return nil
        end
      end

      {
        side: member['party'],
        rank: member['rank'],
        title: member['title'],
        legislator: legislator_cache[member['bioguide']]
      }
    end

    membership_ids = memberships[committee_id].map {|m| m['bioguide']}

    {
      members: members,
      member_ids: membership_ids
    }
  end

end
