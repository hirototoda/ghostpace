#!/usr/bin/env ruby
# frozen_string_literal: true
# GitHub Actions の Mac で TestFlight に送ったあと、その Mac で Xcode が作った開発用の証明書（Apple Development）を取り消す。
# API キーで自動署名すると、新しい Mac では毎回1枚作られ、取り消さないと Apple の上限まで増えるため。docs/decisions/0021
# 取り消すのは「この Mac のキーチェーンに秘密鍵ごとある証明書」だけ（= この実行で作られたもの）。オーナーの Mac の証明書には触れない。
# 環境変数: ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

def jwt
  key = OpenSSL::PKey::EC.new(File.read(ENV.fetch('ASC_KEY_PATH')))
  enc = ->(h) { Base64.urlsafe_encode64(JSON.generate(h), padding: false) }
  now = Time.now.to_i
  data = "#{enc.call(alg: 'ES256', kid: ENV.fetch('ASC_KEY_ID'), typ: 'JWT')}." \
         "#{enc.call(iss: ENV.fetch('ASC_ISSUER_ID'), iat: now, exp: now + 600, aud: 'appstoreconnect-v1')}"
  der = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest.new('SHA256'), data))
  raw = der.value.map { |i| i.value.to_s(2).rjust(32, "\0")[-32, 32] }.join
  "#{data}.#{Base64.urlsafe_encode64(raw, padding: false)}"
end

def api(method, path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP.const_get(method).new(uri)
  req['Authorization'] = "Bearer #{jwt}"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  raise "#{method} #{path}: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  res.body.to_s.empty? ? {} : JSON.parse(res.body)
end

# この Mac に秘密鍵ごとある署名用の証明書（SHA-1）
identities = `security find-identity -v -p codesigning`.scan(/\b([0-9A-F]{40})\b/).flatten.uniq
pems = `security find-certificate -a -p`.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m)
serials = pems.filter_map do |pem|
  cert = OpenSSL::X509::Certificate.new(pem)
  next unless identities.include?(OpenSSL::Digest::SHA1.hexdigest(cert.to_der).upcase)
  next unless cert.subject.to_s.include?('Apple Development')
  cert.serial.to_s(16).upcase
end
if serials.empty?
  puts 'この Mac で作られた開発用の証明書はない'
  exit 0
end

certs = api('Get', '/v1/certificates?filter[certificateType]=DEVELOPMENT,IOS_DEVELOPMENT&limit=200')['data']
targets = certs.select { |c| serials.include?(c.dig('attributes', 'serialNumber').to_s.upcase) }
targets.each do |c|
  api('Delete', "/v1/certificates/#{c['id']}")
  puts "取り消した: #{c.dig('attributes', 'name')}（#{c.dig('attributes', 'serialNumber')}）"
end
left = certs.size - targets.size
puts "残っている開発用の証明書: #{left} 枚"
puts "::warning::開発用の証明書が #{left} 枚ある。Apple の上限に近いなら、Certificates の画面で「Created via API」を整理する" if left >= 5
