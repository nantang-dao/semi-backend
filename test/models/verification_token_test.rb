require "test_helper"

ApplicationController # AppError 定义在这个文件里，模型单独测试时要先加载它

class VerificationTokenTest < ActiveSupport::TestCase
  PHONE = "13800000000"

  def issue(sent_to = PHONE, ip: "1.2.3.4")
    VerificationToken.issue!(context: "phone-login", sent_to: sent_to, ip: ip)
  end

  def consume(code, sent_to = PHONE)
    VerificationToken.consume!(context: "phone-login", sent_to: sent_to, code: code)
  end

  def error_code
    yield
    flunk "expected AppError"
  rescue AppError => e
    e.code
  end

  test "codes are six digits and expire after 15 minutes" do
    code = issue
    assert_match(/\A\d{6}\z/, code)
    travel 16.minutes do
      assert_equal "code_expired", error_code { consume(code) }
    end
  end

  test "a new code invalidates the previous one" do
    old = issue
    travel 61.seconds
    new = issue
    assert_equal 1, VerificationToken.where(used: false).count
    assert_equal "invalid_code", error_code { consume(old) } unless old == new
    consume(new)
  end

  test "a code can be used once" do
    code = issue
    consume(code)
    assert_equal "invalid_code", error_code { consume(code) }
  end

  test "five wrong guesses burn the code" do
    code = issue
    wrong = code == "000000" ? "111111" : "000000"
    5.times { assert_equal "invalid_code", error_code { consume(wrong) } }
    assert_equal "too_many_attempts", error_code { consume(code) }
  end

  test "sending is limited per target: 60s cooldown, 5 per hour" do
    issue
    assert_equal "rate_limited", error_code { issue }
    4.times do
      travel 61.seconds
      issue
    end
    travel 61.seconds
    assert_equal "rate_limited", error_code { issue }
    travel 1.hour
    issue
  end

  test "sending is limited per target: 12 per day" do
    3.times do
      4.times do
        issue
        travel 61.seconds
      end
      travel 1.hour
    end
    assert_equal "rate_limited", error_code { issue }
    travel 1.day
    issue
  end

  test "sending is limited per IP: 30 per hour" do
    30.times { |i| issue("1380000#{i.to_s.rjust(4, "0")}") }
    assert_equal "rate_limited", error_code { issue("13900000000") }
    issue("13900000000", ip: "5.6.7.8")
  end
end
