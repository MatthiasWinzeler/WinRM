module WinRM
  module Transport
    # Uses Kerberos/GSSAPI to authenticate and encrypt messages
    class HttpGSSAPI < Base
      # @param [String,URI] endpoint the WinRM webservice endpoint
      # @param [String] realm the Kerberos realm we are authenticating to
      # @param [String<optional>] service the service name, default is HTTP
      # @param [String<optional>] keytab the path to a keytab file if you are using one
      def initialize(endpoint, opts)
        super(endpoint, opts)
        # Remove the GSSAPI auth from HTTPClient because we are doing our own thing
        auths = @httpcli.www_auth.instance_variable_get('@authenticator')
        auths.delete_if {|i| i.is_a?(HTTPClient::SSPINegotiateAuth)}
        service ||= 'HTTP'
        realm = opts[:realm]
        @service = "#{service}/#{@endpoint.host}@#{realm}"
        init_krb
      end

      def set_auth(user,pass)
        # raise Error
      end

      def send_request(msg)
        original_length = msg.length
        pad_len, emsg = winrm_encrypt(msg)
        hdr = {
          "Connection" => "Keep-Alive",
          "Content-Type" => "multipart/encrypted;protocol=\"application/HTTP-Kerberos-session-encrypted\";boundary=\"Encrypted Boundary\""
        }
debug emsg
        body = <<-EOF
--Encrypted Boundary\r
Content-Type: application/HTTP-Kerberos-session-encrypted\r
OriginalContent: type=application/soap+xml;charset=UTF-8;Length=#{original_length + pad_len}\r
--Encrypted Boundary\r
Content-Type: application/octet-stream\r
#{emsg}--Encrypted Boundary\r
        EOF

        debug body

        r = @httpcli.post(@endpoint, body, hdr)

        winrm_decrypt(r.http_body.content)
      end


      private 
      def init_krb
        debug "Initializing Kerberos for #{@service}"
        @gsscli = GSSAPI::Simple.new(@endpoint.host, @service)
        token = @gsscli.init_context
        auth = Base64.strict_encode64 token

        hdr = {"Authorization" => "Kerberos #{auth}",
          "Connection" => "Keep-Alive",
          "Content-Type" => "application/soap+xml;charset=UTF-8"
        }
        debug "Sending HTTP POST for Kerberos Authentication"
        r = @httpcli.post(@endpoint, '', hdr)
        itok = r.header["WWW-Authenticate"].pop
        itok = itok.split.last
        itok = Base64.strict_decode64(itok)
        @gsscli.init_context(itok)
      end

      # @return [String] the encrypted request string
      def winrm_encrypt(str)
        debug "Encrypting SOAP message:\n#{str}"
        iov_cnt = 3
        iov = FFI::MemoryPointer.new(GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * iov_cnt)

        iov0 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address))
        iov0[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_HEADER | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

        iov1 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 1)))
        iov1[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)
        iov1[:buffer].value = str

        iov2 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 2)))
        iov2[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_PADDING | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

        conf_state = FFI::MemoryPointer.new :uint32
        min_stat = FFI::MemoryPointer.new :uint32

        maj_stat = GSSAPI::LibGSSAPI.gss_wrap_iov(min_stat, @gsscli.context, 1, GSSAPI::LibGSSAPI::GSS_C_QOP_DEFAULT, conf_state, iov, iov_cnt)
        
        token = [iov0[:buffer].length].pack('L')
        #token += iov0[:buffer].value
        token += iov1[:buffer].value
        pad_len = iov2[:buffer].length
        token += iov2[:buffer].value if pad_len > 0
        [pad_len, token]
      end


      # @return [String] the unencrypted response string
      def winrm_decrypt(str)
        debug "Decrypting SOAP message:\n#{str}"
        iov_cnt = 3
        iov = FFI::MemoryPointer.new(GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * iov_cnt)

        iov0 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address))
        iov0[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_HEADER | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

        iov1 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 1)))
        iov1[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)

        iov2 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 2)))
        iov2[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)

        str.force_encoding('BINARY')
        str.sub!(/^.*Content-Type: application\/octet-stream\r\n(.*)--Encrypted.*$/m, '\1')

        len = str.unpack("L").first
        iov_data = str.unpack("LA#{len}A*")
        iov0[:buffer].value = iov_data[1]
        iov1[:buffer].value = iov_data[2]

        min_stat = FFI::MemoryPointer.new :uint32
        conf_state = FFI::MemoryPointer.new :uint32
        conf_state.write_int(1)
        qop_state = FFI::MemoryPointer.new :uint32
        qop_state.write_int(0)

        maj_stat = GSSAPI::LibGSSAPI.gss_unwrap_iov(min_stat, @gsscli.context, conf_state, qop_state, iov, iov_cnt)

        debug "SOAP message decrypted (MAJ: #{maj_stat}, MIN: #{min_stat.read_int}):\n#{iov1[:buffer].value}"

        Nokogiri::XML(iov1[:buffer].value)
      end

    end
  end
end