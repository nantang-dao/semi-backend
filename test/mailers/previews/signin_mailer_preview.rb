# Preview at http://localhost:3000/rails/mailers/signin_mailer/signin
class SigninMailerPreview < ActionMailer::Preview
  def signin
    SigninMailer.with(code: 123456, recipient: "preview@example.com").signin
  end
end
