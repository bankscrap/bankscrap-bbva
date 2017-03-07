require 'bankscrap'

module Bankscrap
  module BBVA
    class Bank < ::Bankscrap::Bank
      BASE_ENDPOINT     = 'https://servicios.bbva.es'.freeze
      LOGIN_ENDPOINT    = '/DFAUTH/slod/DFServletXML'.freeze
      SESSIONS_ENDPOINT = '/ENPP/enpp_mult_web_mobility_02/sessions/v1'.freeze
      PRODUCTS_ENDPOINT = '/ENPP/enpp_mult_web_mobility_02/products/v2'.freeze
      ACCOUNT_ENDPOINT  = '/ENPP/enpp_mult_web_mobility_02/accounts/'.freeze

      # BBVA expects an identifier before the actual User Agent, but 12345 works fine
      USER_AGENT = SecureRandom.hex(64).upcase + ';iPhone;Apple;iPhone5,2;640x1136;iOS;9.3.2;WOODY;5.1.2;xhdpi'.freeze
      REQUIRED_CREDENTIALS = [:user, :password].freeze

      # This is probably some sort of identifier of Android vs iOS consumer app
      CONSUMER_ID = '00000013'.freeze

      def initialize(credentials = {})
        super do
          @user = format_user(@user.dup)

          Bankscrap.proxy = { host: 'localhost', port: 8888 }

          add_headers(
            'User-Agent'       => USER_AGENT,
            'BBVA-User-Agent'  => USER_AGENT,
            'Accept-Language'  => 'spa',
            'Content-Language' => 'spa',
            'Accept'           => 'application/json',
            'Accept-Charset'   => 'UTF-8',
            'Connection'       => 'Keep-Alive',
            'Host'             => 'servicios.bbva.es',
            'ConsumerID'       => CONSUMER_ID
          )
        end
      end

      # Fetch all the accounts for the given user
      # Returns an array of Bankscrap::Account objects
      def fetch_accounts
        log 'fetch_accounts'

        # Even if the required method is an HTTP POST
        # the API requires a funny header that says is a GET
        # otherwise the request doesn't work.
        response = with_headers('BBVA-Method' => 'GET') do
          post(BASE_ENDPOINT + PRODUCTS_ENDPOINT)
        end

        json = JSON.parse(response)
        json['accounts'].map { |data| build_account(data) }
      end

      # Fetch transactions for the given account.
      # By default it fetches transactions for the last month,
      # The maximum allowed by the BBVA API is the last 3 years.
      #
      # Account should be a Bankscrap::Account object
      # Returns an array of Bankscrap::Transaction objects
      def fetch_transactions_for(account, start_date: Date.today - 1.month, end_date: Date.today)
        from_date = start_date.strftime('%Y-%m-%d')

        # Misteriously we need a specific content-type here
        funny_headers = {
          'Content-Type' => 'application/json; charset=UTF-8',
          'BBVA-Method' => 'GET'
        }

        # The API accepts a toDate param that we could pass the end_date argument,
        # however when we pass the toDate param, the API stops returning the account balance.
        # Therefore we need to take a workaround: only filter with fromDate and loop
        # over all the available pages, filtering out the movements that doesn't match
        # the end_date argument.
        url = BASE_ENDPOINT +
              ACCOUNT_ENDPOINT +
              account.id +
              "/movements/v1?fromDate=#{from_date}"

        offset = nil
        pagination_balance = nil
        transactions = []

        with_headers(funny_headers) do
          # Loop over pagination
          loop do
            new_url = offset ? (url + "&offset=#{offset}") : url
            new_url = pagination_balance ? (new_url + "&paginationBalance=#{pagination_balance}") : new_url
            json = JSON.parse(post(new_url))

            unless json['movements'].blank?
              # As explained before, we have to discard records newer than end_date.
              filtered_movements = json['movements'].select { |m| Date.parse(m['operationDate']) <= end_date }

              transactions += filtered_movements.map do |data|
                build_transaction(data, account)
              end
              offset = json['offset']
              pagination_balance = json['paginationBalance']
            end

            break unless json['thereAreMoreMovements'] == true
          end
        end

        transactions
      end

      private

      # As far as we know there are two types of identifiers BBVA uses
      # 1) A number of 7 characters that gets passed to the API as it is
      # 2) A DNI number, this needs to transformed before it get passed to the API
      #    Example: "49021740T" will become "0019-049021740T"
      def format_user(user)
        user.upcase!

        if user =~ /^[0-9]{8}[A-Z]$/
          # It's a DNI
          "0019-0#{user}"
        else
          user
        end
      end

      def login
        log 'login'
        params = {
          'origen'         => 'enpp',
          'eai_tipoCP'     => 'up',
          'eai_user'       => @user,
          'eai_password'   => @password
        }
        post(BASE_ENDPOINT + LOGIN_ENDPOINT, fields: params)

        # We also need to initialize a session
        with_headers('Content-Type' => 'application/json') do
          post(SESSIONS_ENDPOINT, fields: {
            consumerID: CONSUMER_ID
          }.to_json)
        end

        # We need to extract the "tsec" header from the last response.
        # As the Bankscrap core library doesn't expose the headers of each response
        # we have to use Mechanize's HTTP client "current_page" method.
        tsec = @http.current_page.response['tsec']
        add_headers('tsec' => tsec)
      end

      # Build an Account object from API data
      def build_account(data)
        Account.new(
          bank: self,
          id: data['id'],
          name: data['name'],
          available_balance: Money.new(data['availableBalance'].to_f * 100, data['currency']),
          balance: Money.new(data['actualBalance'].to_f * 100, data['currency']),
          iban: data['iban'],
          description: "#{data['typeDescription']} #{data['familyCode']}"
        )
      end

      # Build a transaction object from API data
      def build_transaction(data, account)
        Transaction.new(
          account: account,
          id: data['id'],
          amount: transaction_amount(data),
          description: data['conceptDescription'] || data['description'],
          effective_date: Date.strptime(data['operationDate'], '%Y-%m-%d'),
          balance: transaction_balance(data)
        )
      end

      def transaction_amount(data)
        Money.new(data['amount'] * 100, data['currency'])
      end

      def transaction_balance(data)
        return unless data['accountBalanceAfterMovement']
        Money.new(data['accountBalanceAfterMovement'] * 100, data['currency'])
      end
    end
  end
end
