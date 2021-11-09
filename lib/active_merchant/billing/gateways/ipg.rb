module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class IpgGateway < Gateway
      self.test_url = 'https://test.ipg-online.com/ipgapi/services'
      self.live_url = 'https://www5.ipg-online.com'

      self.supported_countries = %w(UY AR)
      self.default_currency = 'ARS'
      self.supported_cardtypes = %i[visa master american_express discover]

      self.homepage_url = 'https://www.ipg-online.com'
      self.display_name = 'IPG'

      CURRENCY_CODES = {
        'UYU' => '858',
        'ARS' => '032'
      }

      def initialize(options = {})
        requires!(options, :store_id, :user_id, :password, :pem, :pem_password)
        @credentials = options
        super
      end

      def purchase(money, payment, options = {})
        xml = build_purchase_and_authorize_request(money, payment, options)

        commit('sale', xml)
      end

      def authorize(money, payment, options = {})
        xml = build_purchase_and_authorize_request(money, payment, options)

        commit('preAuth', xml)
      end

      def capture(money, authorization, options = {})
        xml = build_capture_and_refund_request(money, authorization, options)

        commit('postAuth', xml)
      end

      def refund(money, authorization, options = {})
        xml = build_capture_and_refund_request(money, authorization, options)

        commit('return', xml)
      end

      def void(authorization, options = {})
        xml = Builder::XmlMarkup.new(indent: 2)
        add_transaction_details(xml, authorization)

        commit('void', xml)
      end

      def store(credit_card, options = {})
        xml = Builder::XmlMarkup.new(indent: 2)
        add_storage_item(xml, credit_card, options)

        commit('vault', xml)
      end

      def verify(credit_card, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
          gsub(%r((<v1:CardNumber>).+(</v1:CardNumber>)), '\1[FILTERED]\2').
          gsub(%r((<v1:CardCodeValue>).+(</v1:CardCodeValue>)), '\1[FILTERED]\2').
          gsub(%r((<v1:StoreId>).+(</v1:StoreId>)), '\1[FILTERED]\2')
      end

      private

      NAMESPACE_BASE_URL = 'http://ipg-online.com'

      def build_purchase_and_authorize_request(money, payment, options)
        xml = Builder::XmlMarkup.new(indent: 2)
        add_payment(xml, payment, options)
        add_three_d_secure(xml, options[:three_d_secure]) if options[:three_d_secure]
        add_stored_credentials(xml, options[:stored_credential]) if options[:stored_credential]
        add_amount(xml, money, options)
        add_transaction_details(xml, options)
        add_billing(xml, options[:billing]) if options[:billing]
        add_shipping(xml, options[:shipping]) if options[:shipping]
        xml
      end

      def build_capture_and_refund_request(money, authorization, options)
        xml = Builder::XmlMarkup.new(indent: 2)
        add_amount(xml, money, options)
        add_transaction_details(xml, authorization, true)
        xml
      end

      def build_order_request(xml, action, body)
        xml.tag!('ipg:IPGApiOrderRequest') do
          xml.tag!('v1:Transaction') do
            add_transaction_type(xml, action)
            xml << body.target!
          end
        end
      end

      def build_action_request(xml, action, body)
        xml.tag!('ns4:IPGApiActionRequest', ipg_action_namespaces) do
          xml.tag!('ns2:Action') do
            xml << body.target!
          end
        end
      end

      def build_soap_request(action, body)
        xml = Builder::XmlMarkup.new(indent: 2)
        xml.tag!('soapenv:Envelope', envelope_namespaces) do
          xml.tag!('soapenv:Header')
          xml.tag!('soapenv:Body') do
            build_order_request(xml, action, body) if action != 'vault'
            build_action_request(xml, action, body) if action == 'vault'
          end
        end
        xml.target!
      end

      def add_stored_credentials(xml, params)
        recurring_type = params[:initial_transaction] ? 'FIRST' : 'REPEAT'
        xml.tag!('v1:recurringType', recurring_type)
      end

      def add_storage_item(xml, credit_card, options)
        requires!(options.merge!({ credit_card: credit_card }), :credit_card, :hosted_data_id)
        xml.tag!('ns2:StoreHostedData') do
          xml.tag!('ns2:DataStorageItem') do
            add_payment(xml, credit_card, {}, 'ns2')
            add_three_d_secure(xml, options[:three_d_secure]) if options[:three_d_secure]
            xml.tag!('ns2:HostedDataID', options[:hosted_data_id]) if options[:hosted_data_id]
          end
        end
      end

      def add_transaction_type(xml, type)
        xml.tag!('v1:CreditCardTxType') do
          xml.tag!('v1:StoreId', @credentials[:store_id])
          xml.tag!('v1:Type', type)
        end
      end

      def add_payment(xml, payment, options = {}, credit_envelope = 'v1')
        requires!(options.merge!({ card_number: payment.number, month: payment.month, year: payment.year }), :card_number, :month, :year) if payment
        if payment
          xml.tag!("#{credit_envelope}:CreditCardData") do
            xml.tag!('v1:CardNumber', payment.number) if payment.number
            xml.tag!('v1:ExpMonth', payment.month) if payment.month
            xml.tag!('v1:ExpYear', payment.year) if payment.year
            xml.tag!('v1:CardCodeValue', payment.verification_value) if payment.verification_value
            xml.tag!('v1:Brand', options[:brand]) if options[:brand]
          end
        end

        if options[:card_function_type]
          xml.tag!('v1:cardFunction') do
            xml.tag!('v1:Type', options[:card_function_type])
          end
        end

        if options[:track_data]
          xml.tag!("#{credit_envelope}:CreditCardData") do
            xml.tag!('v1:TrackData', options[:track_data])
          end
        end
      end

      def add_three_d_secure(xml, three_d_secure)
        xml.tag!('v1:CreditCard3DSecure') do
          xml.tag!('v1:AuthenticationValue', three_d_secure[:cavv]) if three_d_secure[:cavv]
          xml.tag!('v1:XID', three_d_secure[:xid]) if three_d_secure[:xid]
          xml.tag!('v1:Secure3D2TransactionStatus', three_d_secure[:directory_response_status]) if three_d_secure[:directory_response_status]
          xml.tag!('v1:Secure3D2AuthenticationResponse', three_d_secure[:authentication_response_status]) if three_d_secure[:authentication_response_status]
          xml.tag!('v1:Secure3DProtocolVersion', three_d_secure[:version]) if three_d_secure[:version]
          xml.tag!('v1:DirectoryServerTransactionId', three_d_secure[:ds_transaction_id]) if three_d_secure[:ds_transaction_id]
        end
      end

      def add_transaction_details(xml, options, pre_order = false)
        requires!(options, :order_id) if pre_order
        xml.tag!('v1:TransactionDetails') do
          xml.tag!('v1:OrderId', options[:order_id]) if options[:order_id]
          xml.tag!('v1:MerchantTransactionId', options[:merchant_transaction_id]) if options[:merchant_transaction_id]
          xml.tag!('v1:Ip', options[:ip]) if options[:ip]
          xml.tag!('v1:Tdate', options[:t_date]) if options[:t_date]
          xml.tag!('v1:IpgTransactionId', options[:ipg_transaction_id]) if options[:ipg_transaction_id]
          xml.tag!('v1:ReferencedMerchantTransactionId', options[:referenced_merchant_transaction_id]) if options[:referenced_merchant_transaction_id]
          xml.tag!('v1:TransactionOrigin', options[:transaction_origin]) if options[:transaction_origin]
          xml.tag!('v1:InvoiceNumber', options[:invoice_number]) if options[:invoice_number]
          xml.tag!('v1:DynamicMerchantName', options[:dynamic_merchant_name]) if options[:dynamic_merchant_name]
          xml.tag!('v1:Comments', options[:comments]) if options[:comments]
          if options[:terminal_id]
            xml.tag!('v1:Terminal') do
              xml.tag!('v1:TerminalID', options[:terminal_id]) if options[:terminal_id]
            end
          end
        end
      end

      def add_amount(xml, money, options)
        requires!(options.merge!({ money: money }), :currency, :money)
        xml.tag!('v1:Payment') do
          xml.tag!('v1:HostedDataID', options[:hosted_data_id]) if options[:hosted_data_id]
          xml.tag!('v1:HostedDataStoreID', options[:hosted_data_store_id]) if options[:hosted_data_store_id]
          xml.tag!('v1:DeclineHostedDataDuplicates', options[:decline_hosted_data_duplicates]) if options[:decline_hosted_data_duplicates]
          xml.tag!('v1:numberOfInstallments', options[:number_of_installments]) if options[:number_of_installments]
          xml.tag!('v1:SubTotal', options[:sub_total]) if options[:sub_total]
          xml.tag!('v1:ValueAddedTax', options[:value_added_tax]) if options[:value_added_tax]
          xml.tag!('v1:DeliveryAmount', options[:delivery_amount]) if options[:delivery_amount]
          xml.tag!('v1:ChargeTotal', money)
          xml.tag!('v1:Currency', CURRENCY_CODES[options[:currency]])
        end
      end

      def add_billing(xml, billing)
        xml.tag!('v1:Billing') do
          xml.tag!('v1:CustomerID', billing[:customer_id]) if billing[:customer_id]
          xml.tag!('v1:Name', billing[:name]) if billing[:name]
          xml.tag!('v1:Company', billing[:company]) if billing[:company]
          xml.tag!('v1:Address1', billing[:address_1]) if billing[:address_1]
          xml.tag!('v1:Address2', billing[:address_2]) if billing[:address_2]
          xml.tag!('v1:City', billing[:city]) if billing[:city]
          xml.tag!('v1:State', billing[:state]) if billing[:state]
          xml.tag!('v1:Zip', billing[:zip]) if billing[:zip]
          xml.tag!('v1:Country', billing[:country]) if billing[:country]
          xml.tag!('v1:Phone', billing[:phone]) if billing[:phone]
          xml.tag!('v1:Fax', billing[:fax]) if billing[:fax]
          xml.tag!('v1:Email', billing[:email]) if billing[:email]
        end
      end

      def add_shipping(xml, shipping)
        xml.tag!('v1:Shipping') do
          xml.tag!('v1:Type', shipping[:type]) if shipping[:type]
          xml.tag!('v1:Name', shipping[:name]) if shipping[:name]
          xml.tag!('v1:Address1', shipping[:address_1]) if shipping[:address_1]
          xml.tag!('v1:Address2', shipping[:address_2]) if shipping[:address_2]
          xml.tag!('v1:City', shipping[:city]) if shipping[:city]
          xml.tag!('v1:State', shipping[:state]) if shipping[:state]
          xml.tag!('v1:Zip', shipping[:zip]) if shipping[:zip]
          xml.tag!('v1:Country', shipping[:country]) if shipping[:country]
        end
      end

      def build_header
        {
          'Content-Type' => 'text/xml; charset=utf-8',
          'Authorization' => "Basic #{encoded_credentials}"
        }
      end

      def encoded_credentials
        Base64.encode64("WS#{@credentials[:store_id]}._.#{@credentials[:user_id]}:#{@credentials[:password]}").delete("\n")
      end

      def envelope_namespaces
        {
          'xmlns:soapenv' => 'http://schemas.xmlsoap.org/soap/envelope/',
          'xmlns:ipg' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/ipgapi",
          'xmlns:v1' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/v1"
        }
      end

      def ipg_order_namespaces
        {
          'xmlns:v1' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/v1",
          'xmlns:ipgapi' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/ipgapi"
        }
      end

      def ipg_action_namespaces
        {
          'xmlns:ns4' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/ipgapi",
          'xmlns:ns2' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/a1",
          'xmlns:ns3' => "#{NAMESPACE_BASE_URL}/ipgapi/schemas/v1"
        }
      end

      def commit(action, request)
        url = (test? ? test_url : live_url)
        soap_request = build_soap_request(action, request)
        response = parse(ssl_post(url, soap_request, build_header))
        Response.new(
          response[:success],
          message_from(response),
          response,
          authorization: authorization_from(response),
          avs_result: AVSResult.new(code: response[:AVSResponse]),
          cvv_result: CVVResult.new(response[:ProcessorCCVResponse]),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def parse(xml)
        reply = {}
        xml = REXML::Document.new(xml)
        root = REXML::XPath.first(xml, '//ipgapi:IPGApiOrderResponse') || REXML::XPath.first(xml, '//ipgapi:IPGApiActionResponse') || REXML::XPath.first(xml, '//SOAP-ENV:Fault')
        reply[:success] = REXML::XPath.first(xml, '//faultcode') ? false : true
        root.elements.to_a.each do |node|
          parse_element(reply, node)
        end
        return reply
      end

      def parse_element(reply, node)
        if node.has_elements?
          node.elements.each { |e| parse_element(reply, e) }
        else
          if /item/.match?(node.parent.name)
            parent = node.parent.name
            parent += '_' + node.parent.attributes['id'] if node.parent.attributes['id']
            parent += '_'
          end
          reply["#{parent}#{node.name}".to_sym] ||= node.text
        end
        return reply
      end

      def message_from(response)
        response[:TransactionResult]
      end

      def authorization_from(response)
        {
          order_id: response[:OrderId],
          ipg_transaction_id: response[:IpgTransactionId]
        }
      end

      def error_code_from(response)
        response[:ErrorMessage]&.split(':')&.first unless response[:success]
      end

      def handle_response(response)
        case response.code.to_i
        when 200...300, 500
          response.body
        else
          raise ResponseError.new(response)
        end
      end
    end
  end
end