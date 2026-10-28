module Signals
  # Cosa avrebbe fatto la regola sullo storico, confrontata con "compra e tieni".
  # Il segnale di un giorno si conosce solo a candela chiusa: si esegue all'apertura della
  # candela successiva, pagando la commissione a ogni acquisto e vendita. Lo stop indicativo
  # non viene simulato.
  class Backtest
    Trade = Struct.new(:entry_date, :entry, :exit_date, :exit, :return_percent, :open, keyword_init: true)
    Result = Struct.new(:from, :to, :total_percent, :annual_percent, :max_drawdown_percent, :trades,
                        :exposure_percent, :hold_total_percent, :hold_annual_percent, :hold_max_drawdown_percent,
                        keyword_init: true) do
      def closed_trades = trades.reject(&:open)
      def win_rate_percent = closed_trades.empty? ? nil : closed_trades.count { |t| t.return_percent.positive? } * 100.0 / closed_trades.size
    end

    def self.run(candles, positions, fee_percent:)
      new(candles, positions, fee_percent).run
    end

    def initialize(candles, positions, fee_percent)
      @candles = candles
      @positions = positions
      @fee = fee_percent.to_f / 100
    end

    def run
      first = @positions.index { |p| !p.nil? }
      return nil if first.nil? || first + 1 >= @candles.size

      cash, units = 1.0, 0.0
      trades, values, days_in = [], [], 0
      (first + 1...@candles.size).each do |i|
        want = @positions[i - 1] # deciso alla chiusura di ieri, eseguito all'apertura di oggi
        price = @candles[i].open
        if want && units.zero?
          units = cash * (1 - @fee) / price
          cash = 0.0
          trades << Trade.new(entry_date: @candles[i].date, entry: price, open: true)
        elsif !want && units.positive?
          cash = units * price * (1 - @fee)
          units = 0.0
          close_trade(trades.last, @candles[i].date, price)
        end
        days_in += 1 if units.positive?
        values << cash + units * @candles[i].close
      end
      if (last = trades.last)&.open # posizione ancora aperta: valutata all'ultima chiusura
        last.return_percent = ((@candles.last.close * (1 - @fee)) / (last.entry / (1 - @fee)) - 1) * 100
      end

      hold = hold_values(first + 1)
      years = (@candles.last.date - @candles[first + 1].date).to_f / 365.25
      Result.new(
        from: @candles[first + 1].date, to: @candles.last.date, trades: trades,
        total_percent: (values.last - 1) * 100, annual_percent: annual(values.last, years),
        max_drawdown_percent: drawdown(values), exposure_percent: days_in * 100.0 / values.size,
        hold_total_percent: (hold.last - 1) * 100, hold_annual_percent: annual(hold.last, years),
        hold_max_drawdown_percent: drawdown(hold)
      )
    end

    private

    def close_trade(trade, date, price)
      trade.exit_date = date
      trade.exit = price
      trade.open = false
      trade.return_percent = ((price * (1 - @fee)) / (trade.entry / (1 - @fee)) - 1) * 100
    end

    def hold_values(start)
      units = (1 - @fee) / @candles[start].open
      @candles[start..].map { |c| units * c.close }
    end

    def annual(final, years)
      return nil if years < 1 || final <= 0

      (final**(1 / years) - 1) * 100
    end

    # Il ribasso più profondo da un massimo precedente (numero negativo).
    def drawdown(values)
      peak = values.first
      values.map { |v| peak = [peak, v].max; (v / peak - 1) * 100 }.min
    end
  end
end
