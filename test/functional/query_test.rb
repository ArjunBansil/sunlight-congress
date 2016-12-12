require './test/test_helper'

class QueryTest < Test::Unit::TestCase
  include Rack::Test::Methods
  include TestHelper::Methods

  def test_fields_with_dollar_signs_are_gracefully_ignored
    vote = Vote.create!(
      roll_id: "h509-2013",
      voters: {
        "L000551" => {
          vote: "Yea",
          voter: {bioguide_id: "L000551"}
        }
      }
    )

    get "/votes", {
      roll_id: "h509-2013",

      # doesn't apply here, but was crashing the app in production once
      fields: "roll_id,voters.$.voter_id"
    }

    assert_response 200
    assert_json

    assert_match /h509-2013/, last_response.body
  end

  def test_rss_doesnt_crash
    bill = Bill.create!(
      official_title: "A title",
      bill_id: "hr1234-113",
      urls: {
        congress: "https://www.congress.gov/bill/113th-congress/house-bill/1234"
      },
      introduced_on: "2013-04-05",
      summary: "A great bill"
    )

    get "/bills", {
      bill_id: "hr1234-113",
      format: "rss"
    }

    assert_response 200
    assert_xml

    assert_match /<rss/, last_response.body
    assert_match /hr1234/, last_response.body
  end

  def test_rss_json_doesnt_crash
    bill = Bill.create!(
      official_title: "A title",
      bill_id: "hr1234-113",
      urls: {
        congress: "https://www.congress.gov/bill/113th-congress/house-bill/1234"
      },
      introduced_on: "2013-04-05",
      summary: "A great bill"
    )

    get "/bills", {
      bill_id: "hr1234-113",
      format: "rss-json"
    }

    assert_response 200
    assert_json

    assert_match /@item/, last_response.body
    assert_match /@channel/, last_response.body
    assert_match /hr1234/, last_response.body
  end

  def test_boolean_parsing
    bill = Bill.create!(
      bill_id: "hr1234-113",
      introduced_on: "2013-04-05",
      history: {
        enacted: true
      }
    )

    # TODO: move "True" case to the success array
    success = [true, "true"]
    failure = [false, "false", "False", "True"]

    # note: using nil or '' will cause the query to be disregarded,
    # which will make the bill return, but not because of the behavior
    # this test is evaluating (so is not tested here).

    success.each do |value|
      get "/bills", {
        bill_id: "hr1234-113",
        "history.enacted" => value
      }

      assert_response 200
      assert_json

      assert_match /hr1234/, last_response.body, "Using history.enacted = #{value}"
    end

    failure.each do |value|
      get "/bills", {
        bill_id: "hr1234-113",
        "history.enacted" => value
      }

      assert_response 200
      assert_json

      assert_no_match /hr1234/, last_response.body, "Using history.enacted = #{value}"
    end
  end

end