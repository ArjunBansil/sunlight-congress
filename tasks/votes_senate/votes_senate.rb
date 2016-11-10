require 'nokogiri'

class VotesSenate

  # Syncs vote data with the House of Representatives.
  #
  # By default, looks through the Clerk's EVS pages, and
  # re/downloads data for the last 10 roll call votes.
  #
  # Options can be passed in to archive whole years, which can ignore
  # already downloaded files (to support resuming).
  #
  # options:
  #   force: if archiving, force it to re-download existing files.
  #   congress: archive an entire congress' worth of votes (defaults to latest 20)
  #   session: archive a specific session within a congress (typically, 1 or 2)
  #   roll_id: only download a specific roll call vote (Senate only). Ignores other options.
  #   limit: only download a certain number of votes (stop short, useful for testing/development)
  #   skip_text: don't search index related text

  def self.run(options = {})
    # if specifying a congress, turn on archive mode,
    # fetch all sessions unless that is also specified
    if options[:congress]
      congress = options[:congress].to_i
      sessions = options[:session] ? [options[:session]] : ["1", "2"]
      limit = options[:limit] ? options[:limit].to_i : nil

    # by default, fetch the current congress' current session
    else
      congress = Utils.current_congress
      # just the last session for that congress
      year = Utils.current_legislative_year
      session = year % 2
      session = 2 if session == 0
      sessions = [session.to_s]
      limit = options[:limit] ? options[:limit].to_i : 20
    end

    initialize_disk! congress

    if options[:roll_id]
      to_get = [options[:roll_id]]
    else
      to_get = []

      sessions.reverse.each do |session|
        unless rolls = rolls_for(congress, session, options)
          Report.note self, "Failed to find the latest new roll on the Senate's site, can't go on."
          next
        end

        to_get += rolls.reverse
      end

      if limit
        to_get = to_get.first limit.to_i
      end
    end

    count = 0

    download_failures = []
    missing_legislators = []
    missing_bill_ids = []
    missing_nomination_ids = []
    missing_amendment_ids = []

    # will be referenced by LIS ID as a cache built up as we parse through votes
    legislators = {}

    to_get.each do |roll_id|
      number, year = roll_id.tr('s', '').split("-").map &:to_i
      congress = Utils.congress_for_year year
      session = Utils.legislative_session_for_year year

      puts "[#{roll_id}] Syncing to disc..." if options[:debug]
      unless download_roll year, congress, session, number, download_failures, options
        puts "[#{roll_id}] WARNING: Couldn't sync to disc, skipping"
        next
      end

      doc = Nokogiri::XML open(destination_for(year, number))
      puts "[#{roll_id}] Saving vote information..." if options[:debug]


      bill_id = bill_id_for doc, congress
      amendment_id = amendment_id_for doc, congress
      nomination_id = nomination_id_for doc, congress
      voter_ids, voters = votes_for doc, legislators, missing_legislators

      roll_type = doc.at("question").text
      question = doc.at("vote_question_text").text
      result = doc.at("vote_result").text

      vote = Vote.find_or_initialize_by roll_id: roll_id
      vote.attributes = {
        vote_type: Utils.vote_type_for(roll_type, question),
        chamber: "senate",
        year: year,
        number: number,

        congress: congress,
        session: session,

        roll_type: roll_type,
        question: question,
        result: result,
        required: required_for(doc),

        voted_at: voted_at_for(doc),
        voter_ids: voter_ids,
        voters: voters,

        breakdown: Utils.vote_breakdown_for(voters),

        source: url_for(congress, session, number),
        url: landing_url_for(congress, session, number)
      }

      if bill_id
        if bill = Utils.bill_for(bill_id)
          vote.attributes = {
            bill_id: bill_id,
            bill: bill
          }
        else
          missing_bill_ids << {roll_id: roll_id, bill_id: bill_id}
        end
      end

      # for now, only bother with amendments on bills
      if bill_id and amendment_id
        if amendment = Utils.amendment_for(amendment_id)
          vote.attributes = {
            amendment_id: amendment_id,
            amendment: amendment
          }
        else
          missing_amendment_ids << {roll_id: roll_id, amendment_id: amendment_id}
        end
      end

      if nomination_id
        if nomination = Utils.nomination_for(nomination_id)
          vote.attributes = {
            nomination_id: nomination_id,
            nomination: nomination
          }
        else
          missing_nomination_ids << {roll_id: roll_id, nomination_id: nomination_id}
        end
      end

      vote.save!

      count += 1
    end

    if download_failures.any?
      Report.warning self, "Failed to download #{download_failures.size} files while syncing against the House Clerk votes collection for #{year}", download_failures: download_failures
    end

    if missing_legislators.any?
      Report.warning self, "Couldn't look up #{missing_legislators.size} legislators in Senate roll call listing. Vote counts on roll calls may be inaccurate until these are fixed.", missing_legislators: missing_legislators
    end

    if missing_bill_ids.any?
      Report.note self, "Found #{missing_bill_ids.size} missing bill_id's while processing votes.", missing_bill_ids: missing_bill_ids
    end

    if missing_nomination_ids.any?
      Report.warning self, "Found #{missing_nomination_ids.size} missing nomination_id's while processing votes.", missing_nomination_ids: missing_nomination_ids
    end

    if missing_amendment_ids.any?
      Report.note self, "Found #{missing_amendment_ids.size} missing amendment_id's while processing votes.", missing_amendment_ids: missing_amendment_ids
    end

    Report.success self, "Successfully synced #{count} Senate roll call votes from the #{congress}th Congress"
  end

  def self.initialize_disk!(congress)
    Utils.years_for_congress(congress).each do |year|
      FileUtils.mkdir_p "data/senate/rolls/#{year}"
    end
  end

  def self.destination_for(year, number)
    "data/senate/rolls/#{year}/#{zero_prefix number}.xml"
  end


  # find the latest roll call number listed on the Senate roll call vote page for a given year
  def self.rolls_for(congress, session, options = {})
    url = "http://www.senate.gov/legislative/LIS/roll_call_lists/vote_menu_#{congress}_#{session}.xml"
    puts "[#{congress}-#{session}] Fetching xml index page for #{url} from Senate website..." if options[:debug]
    
    return nil unless doc = Utils.xml_for(url)
    latest = doc.xpath("//vote_number")[0].text.to_i rescue nil
    return nil unless latest != nil

    if latest > 0
      (1..latest).map do |number|
        roll_id_for number, congress, session
      end
    else
      []
    end
  end

  def self.url_for(congress, session, number)
    "http://www.senate.gov/legislative/LIS/roll_call_votes/vote#{congress}#{session}/vote_#{congress}_#{session}_#{zero_prefix number}.xml"
  end

  def self.landing_url_for(congress, session, number)
    "http://www.senate.gov/legislative/LIS/roll_call_lists/roll_call_vote_cfm.cfm?congress=#{congress}&session=#{session}&vote=#{zero_prefix number}"
  end

  def self.zero_prefix(number)
    if number < 10
      "0000#{number}"
    elsif number < 100
      "000#{number}"
    elsif number < 1000
      "00#{number}"
    elsif number < 10000
      "0#{number}"
    else
      number.to_s
    end
  end

  def self.short_zero_prefix(number)
    if number < 10
      "0#{number}"
    else
      number.to_s
    end
  end

  def self.required_for(doc)
    doc.at("majority_requirement").text
  end

  def self.votes_for(doc, legislators, missing_legislators)
    voter_ids = {}
    voters = {}

    doc.search("//members/member").each do |elem|
      vote = (elem / 'vote_cast').text

      # override special arrangement, seen in s5-2009:
      # http://www.senate.gov/legislative/LIS/roll_call_votes/vote1111/vote_111_1_00005.xml
      # and explained here:
      # http://en.wikipedia.org/wiki/Live_pair
      if vote == "Present, Giving Live Pair"
        vote = "Present"
      end

      lis_id = (elem / 'lis_member_id').text

      legislators[lis_id] ||= lookup_legislator lis_id, elem

      if legislators[lis_id]
        voter = legislators[lis_id]
        bioguide_id = voter['bioguide_id']
        voter_ids[bioguide_id] = vote
        voters[bioguide_id] = {vote: vote, voter: voter}
      else
        missing_legislators << {lis_id: lis_id, member_full: elem.at("member_full").text, number: doc.at("vote_number").text.to_i}
      end
    end

    [voter_ids, voters]
  end

  def self.lookup_legislator(lis_id, element)
    legislator = Legislator.where(lis_id: lis_id).first
    legislator ? Utils.legislator_for(legislator) : nil
  end

  def self.nomination_id_for(doc, congress)
    return unless (document = doc.at('document')) and (type = document.at('document_type')) and (type.text.strip == "PN")
    number = document.at('document_name').text.strip

    if (pieces = number.split("-")).size > 1
      number = "#{pieces[0]}-#{short_zero_prefix pieces[1].to_i}"
    end

    return "#{number}-#{congress}"
  end

  def self.bill_id_for(doc, congress)
    elem = doc.at 'document_name'
    if !(elem and elem.text.present?)
      elem = doc.at 'amendment_to_document_number'
    end

    if elem and elem.text.present?
      code = elem.text.strip.gsub(' ', '').gsub('.', '').downcase
      type = code.gsub /\d/, ''
      number = code.gsub type, ''

      if ["hr", "hres", "hjres", "hconres", "s", "sres", "sjres", "sconres"].include?(type)
        "#{type}#{number}-#{congress}"
      else
        nil
      end
    else
      nil
    end
  end

  # use new amdt ID format -
  # [s|h]amdt[number]-[congress]
  def self.amendment_id_for(doc, congress)
    elem = doc.at 'amendment_number'
    if elem and elem.text.present?
      number = elem.text.gsub(/[^\d]/, '').to_i
      "samdt#{number}-#{congress}"
    else
      nil
    end
  end

  def self.voted_at_for(doc)
    Utils.utc_parse doc.at("vote_date").text
  end

  def self.download_roll(year, congress, session, number, failures, options = {})
    url = url_for congress, session, number
    destination = destination_for year, number
    puts "#{url}"
    # cache aggressively, redownload only if force option is passed
    if File.exists?(destination) and options[:force].blank?
      puts "\tCached at #{destination}" if options[:debug]
      return true
    end

    puts "\tDownloading #{url} to #{destination}" if options[:debug]

    unless curl = Utils.curl(url, destination)
      puts "Couldn't download #{url}" if options[:debug]
      failures << {message: "Couldn't download", url: url, destination: destination}
      return false
    end

    unless curl.content_type == "application/xml" or curl.content_type == 'text/xml'
      # don't consider it a failure - the vote's probably just not up yet
      # failures << {message: "Wrong content type", url: url, destination: destination, content_type: curl.content_type}
      puts "Wrong content type for #{url}" if options[:debug]
      FileUtils.rm destination # delete bad file from the cache
      return false
    end

    # sanity check on files less than expected -
    # most are ~23K, so if something is less than 20K, check the XML for malformed errors
    if curl.downloaded_content_length < 20000
      # retry once, quick check
      puts "\tRe-downloading once, looked truncated" if options[:debug]
      curl = Utils.curl(url, destination)

      if curl.downloaded_content_length < 20000
        begin
          Nokogiri::XML(open(destination)) {|config| config.strict}
        rescue
          puts "\tFailed strict XML check, assuming it's still truncated" if options[:debug]
          failures << {message: "Failed check", url: url, destination: destination, content_length: curl.downloaded_content_length}
          FileUtils.rm destination
          return false
        else
          puts "\tOK, passes strict XML check, accepting it" if options[:debug]
        end
      end
    end

    true
  end

  # infer year for a roll ID, given its number, congress, and session
  # year is a "legislative year", consistently determinable from the congress/session
  def self.roll_id_for(number, congress, session)
    years = Utils.years_for_congress congress
    if session == "1"
      year = years[0]
    elsif session == "2"
      year = years[1]
    else
      return nil # unhandled right now
    end

    "s#{number}-#{year}"
  end

end

# Shorten timeout in Net::HTTP
require 'net/http'
module Net
  class HTTP
    alias old_initialize initialize

    def initialize(*args)
      old_initialize(*args)
      @read_timeout = 8 # 8 seconds
    end
  end
end
