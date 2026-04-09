class SigninMailer < ApplicationMailer
    default from: 'Semi <semi@semi.ntdao.xyz>'
    def signin
      @code = params[:code]
      @recipient = params[:recipient]
      mail(to: [@recipient], subject: 'Semi Sign-In')
    end
end
