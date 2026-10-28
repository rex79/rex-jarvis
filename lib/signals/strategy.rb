module Signals
  module Indicators
    # Media mobile semplice; nil finché non ci sono abbastanza giorni.
    def self.sma(values, n)
      sum = 0.0
      values.each_with_index.map do |v, i|
        sum += v
        sum -= values[i - n] if i >= n
        i >= n - 1 ? sum / n : nil
      end
    end

    # Average True Range (media semplice del true range): quanto si muove il prezzo in un giorno tipico.
    def self.atr(candles, n)
      ranges = candles.each_with_index.map do |c, i|
        prev = i.zero? ? c.close : candles[i - 1].close
        [c.high - c.low, (c.high - prev).abs, (c.low - prev).abs].max
      end
      sma(ranges, n)
    end
  end

  Signal = Struct.new(:product, :date, :action, :close, :fast, :slow, :atr, :stop, :since, :params, keyword_init: true) do
    def base = product.split("-").first
    def quote = product.split("-").last
    def gap_percent = slow && (close / slow - 1) * 100
  end

  # Regola di trend: DENTRO se la chiusura è sopra la media lenta e la veloce sopra la lenta.
  # Nessun modello e nessuna discrezionalità: lo stesso storico dà sempre lo stesso segnale.
  class Strategy
    ACTIONS = {
      entra: "ENTRA", esci: "ESCI", resta_dentro: "RESTA DENTRO", resta_fuori: "RESTA FUORI", dati_insufficienti: "DATI INSUFFICIENTI"
    }.freeze

    attr_reader :fast, :slow, :atr, :stop_atr

    def initialize(fast: 50, slow: 200, atr: 14, stop_atr: 3)
      raise ArgumentError, "la media veloce (#{fast}) deve essere più corta della lenta (#{slow})" unless fast.to_i.positive? && fast.to_i < slow.to_i

      @fast, @slow, @atr, @stop_atr = fast.to_i, slow.to_i, atr.to_i, stop_atr.to_f
    end

    def self.from_config(cfg)
      new(**(cfg || {}).transform_keys(&:to_sym).slice(:fast, :slow, :atr, :stop_atr))
    end

    # Per ogni giorno: true (dentro), false (fuori) o nil (medie non ancora calcolabili).
    def positions(candles)
      closes = candles.map(&:close)
      f = Indicators.sma(closes, @fast)
      s = Indicators.sma(closes, @slow)
      closes.each_index.map { |i| s[i] && f[i] && closes[i] > s[i] && f[i] > s[i] }
    end

    def signal(product, candles)
      pos = positions(candles)
      last = candles.last
      return Signal.new(product: product, date: last&.date, action: :dati_insufficienti, params: params) if last.nil? || pos.last.nil?

      closes = candles.map(&:close)
      atr = Indicators.atr(candles, @atr).last
      changed = (1...pos.size).reverse_each.find { |i| !pos[i - 1].nil? && pos[i] != pos[i - 1] }
      action = if pos[-2].nil? || pos[-1] == pos[-2]
                 pos[-1] ? :resta_dentro : :resta_fuori
               else
                 pos[-1] ? :entra : :esci
               end

      Signal.new(
        product: product, date: last.date, action: action, close: last.close,
        fast: Indicators.sma(closes, @fast).last, slow: Indicators.sma(closes, @slow).last, atr: atr,
        stop: pos[-1] && atr ? last.close - @stop_atr * atr : nil,
        since: changed && candles[changed].date, params: params
      )
    end

    def params = { fast: @fast, slow: @slow, atr: @atr, stop_atr: @stop_atr }
  end
end
