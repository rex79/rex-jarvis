require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] ||= Dir.mktmpdir("personal")
require_relative "dispensa"

class DispensaTest < Minitest::Test
  class FakeLLM
    attr_reader :messages

    def initialize(fail: false, reply: " Una frittata di zucchine. ") = (@fail = fail; @reply = reply)

    def chat(messages, **)
      raise "HTTP 402" if @fail

      @messages = messages
      { "message" => { "content" => @reply } }
    end
  end

  def setup
    @file = File.join(Dir.mktmpdir, "casa", "dispensa.md")
    @llm = FakeLLM.new
    @mod = Dispensa::Module.new(store: Dispensa::Store.new(@file), llm: @llm, clock: -> { Date.new(2026, 11, 11) })
  end

  def test_adds_spoken_items_to_the_right_place
    assert_equal "Aggiunto nel congelatore: due confezioni di piselli e pane.",
                 @mod.handle("Aggiungi agli alimenti in congelatore due confezioni di piselli e il pane.")
    assert_equal "Aggiunto in frigo: zucchine, 6 uova e una mozzarella.", @mod.handle("Jarvis, metti in frigo le zucchine, 6 uova e una mozzarella")
    assert_equal "Aggiunto nel congelatore: petto di pollo.", @mod.handle("Ho messo nel freezer il petto di pollo")
    note = File.read(@file)
    assert_includes note, "## Congelatore\n- due confezioni di piselli (dal 2026-11-11)\n- pane (dal 2026-11-11)\n- petto di pollo (dal 2026-11-11)"
    assert_includes note, "## Frigo\n- zucchine (dal 2026-11-11)"
    assert_equal "Cosa aggiungo in dispensa?", @mod.handle("aggiungi in dispensa")
  end

  def test_same_food_is_updated_not_doubled
    @mod.handle("aggiungi al congelatore i piselli")
    @mod.handle("aggiungi al congelatore 2 confezioni di pisello")
    assert_equal "Nel congelatore hai: 2 confezioni di pisello.", @mod.handle("cosa ho in congelatore?")
  end

  def test_lists_one_place_or_everything
    @mod.handle("metti in frigo il latte")
    assert_equal "Il congelatore è vuoto.", @mod.handle("Cosa c'è nel congelatore?")
    assert_equal "Il congelatore è vuoto. In frigo hai: latte. La dispensa è vuota.", @mod.handle("cosa ho in casa?")
  end

  def test_removes_by_meaningful_words_wherever_the_food_is
    @mod.handle("aggiungi al congelatore due confezioni di piselli e il petto di pollo")
    assert_equal "Tolto dal congelatore: due confezioni di piselli.", @mod.handle("Ho finito i piselli")
    assert_equal "Tolto dal congelatore: petto di pollo.", @mod.handle("togli il pollo dal freezer")
    assert_equal "Non trovo latte in frigo.", @mod.handle("togli dal frigo il latte")
  end

  def test_unrelated_sentences_are_left_to_the_agent
    @mod.handle("aggiungi al congelatore i piselli")
    ["ho finito il report per il cliente", "aggiungi una nota sul progetto", "a che ora ceniamo sabato",
     "metti un po' di musica", "cancella la nota di ieri", "che tempo fa"].each do |text|
      assert_nil @mod.handle(text), text
    end
  end

  def test_cooking_questions_send_only_food_and_request_to_the_model
    @mod.handle("aggiungi al congelatore il salmone")
    assert_equal "Una frittata di zucchine.", @mod.handle("Ho in frigo zucchine e uova, cosa posso cucinare?").text
    user = @llm.messages.last[:content]
    assert_includes user, "Congelatore: salmone"
    assert_includes user, "Frigo: niente"
    assert_includes user, "Richiesta: Ho in frigo zucchine e uova, cosa posso cucinare?"
    assert_equal "Nel congelatore hai: salmone.\n\nUna frittata di zucchine.",
                 @mod.handle("Cosa ho in congelatore e che posso mangiare a pranzo o cena?").text
    refute_includes File.read(@file), "zucchine" # dire cosa c'è in frigo non lo aggiunge all'elenco
  end

  def test_a_recipe_request_is_not_tied_to_the_food_at_home
    @mod.handle("metti in frigo le zucchine")
    ["Cercami la ricetta della carbonara", "Mi dai un'idea per un dolce?", "Cosa posso cucinare stasera per cena?",
     "Una ricetta veloce con il salmone"].each do |text|
      @mod.handle(text)
      assert_includes @llm.messages.first[:content], "Non sai cosa ha in casa", text
      refute_includes @llm.messages.last[:content], "zucchine", text
      assert_includes @llm.messages.last[:content], "Richiesta: #{text}", text
    end
  end

  def test_the_food_at_home_is_used_only_when_asked
    @mod.handle("metti in frigo le zucchine")
    ["Cosa cucino con quello che ho in casa?", "Una ricetta con gli avanzi", "Che ricetta posso fare con quello che c'è in dispensa?",
     "Cosa preparo con quello che abbiamo?"].each do |text|
      @mod.handle(text)
      assert_includes @llm.messages.first[:content], "con quello che ha in casa", text
      assert_includes @llm.messages.last[:content], "Frigo: zucchine", text
    end
  end

  def test_a_follow_up_switches_the_previous_request_to_the_food_at_home
    @mod.handle("metti in frigo le zucchine")
    @mod.handle("Dammi un'idea per un primo piatto")
    refute_includes @llm.messages.last[:content], "zucchine"
    @mod.handle("Ok, vai con quello che ho in frigo")
    user = @llm.messages.last[:content]
    assert_includes user, "Frigo: zucchine"
    assert_includes user, "Richiesta: Dammi un'idea per un primo piatto\nPoi ha aggiunto: Ok, vai con quello che ho in frigo"
    assert_equal "In frigo hai: zucchine.", @mod.handle("fai l'elenco di cosa ho in frigo") # elencare resta elencare
  end

  def test_each_proposed_dish_gets_a_cookidoo_search_link
    llm = FakeLLM.new(reply: "**Frittata** di zucchine: sbatti le uova.\n\n- Salmone al forno.\n\nRICERCHE: Frittata di zucchine; salmone al forno!; <script>; ; quarto; quinto")
    reply = Dispensa::Module.new(store: Dispensa::Store.new(@file), llm: llm).handle("cosa posso cucinare per cena?")
    assert_equal "Frittata di zucchine: sbatti le uova.\n\nSalmone al forno.", reply.text
    assert_equal ["Cookidoo: Frittata di zucchine", "Cookidoo: salmone al forno", "Cookidoo: script"], reply.links.map { |l| l[:title] }
    assert_equal "https://cookidoo.it/search/it-IT?query=Frittata+di+zucchine", reply.links.first[:url]
    assert reply.links.all? { |l| l[:frame] && l[:url].start_with?("https://cookidoo.it/search/it-IT?query=") }
    assert_equal ["https://cookidoo.it"], @mod.frame_sources
    assert_empty @mod.handle("cosa posso cucinare?").links # nessuna ricerca dal modello e casa vuota: nessun link
    @mod.handle("metti in frigo 6 uova e due confezioni di zucchine")
    assert_equal ["Cookidoo: uova zucchine"], @mod.handle("cosa posso cucinare con quello che ho?").links.map { |l| l[:title] } # ripiego: gli alimenti in casa
    assert_equal ["Cookidoo: carbonara"], @mod.handle("Cercami la ricetta della carbonara").links.map { |l| l[:title] } # ripiego: il piatto chiesto
  end

  def test_when_the_model_fails_the_list_is_still_given
    mod = Dispensa::Module.new(store: Dispensa::Store.new(@file), llm: FakeLLM.new(fail: true))
    mod.handle("metti in frigo le uova")
    reply = mod.handle("cosa posso cucinare stasera con quello che ho in casa?")
    assert_includes reply, "In frigo hai: uova."
    assert_includes reply, "Non riesco a chiedere idee al modello online (HTTP 402)"
    assert_equal "Non riesco a chiedere idee al modello online (HTTP 402).", mod.handle("la ricetta del tiramisù")
  end

  def test_hand_edited_notes_are_read_and_kept
    FileUtils.mkdir_p(File.dirname(@file))
    File.write(@file, "# Dispensa\n\n## Frigo\n- burro\n* yogurt (dal 2026-11-01)\nriga strana\n\n## Cantina\n- vino\n")
    assert_equal "In frigo hai: burro e yogurt.", @mod.handle("cosa ho in frigo")
    @mod.handle("metti in frigo il latte")
    assert_includes File.read(@file), "- burro\n- yogurt (dal 2026-11-01)\n- latte (dal 2026-11-11)"
  end

  def test_agent_tools
    assert_equal "Aggiunto in dispensa: pasta e riso.", @mod.call_tool("dispensa_aggiungi", { "posto" => "dispensa", "alimenti" => %w[pasta riso] })
    assert_equal "In dispensa hai: pasta e riso.", @mod.call_tool("dispensa_elenco", { "posto" => "dispensa" })
    assert_equal "Tolto dalla dispensa: riso.", @mod.call_tool("dispensa_togli", { "alimenti" => ["riso"] })
    assert_equal "Una frittata di zucchine.", @mod.call_tool("idee_pasto", { "richiesta" => "cena veloce" })
    refute_includes @llm.messages.last[:content], "Alimenti in casa"
    @mod.call_tool("idee_pasto", { "richiesta" => "cena veloce", "usa_alimenti_in_casa" => true })
    assert_includes @llm.messages.last[:content], "Dispensa: pasta"
    assert_raises(ArgumentError) { @mod.call_tool("dispensa_aggiungi", { "posto" => "cantina", "alimenti" => ["vino"] }) }
  end

  def test_dashboard_api
    data = @mod.api("POST", "aggiungi", JSON.generate(posto: "frigo", testo: "Latte, 6 uova"), {})
    assert_equal "Aggiunto in frigo: latte e 6 uova.", data[:text]
    assert_equal %w[latte], @mod.api("POST", "togli", JSON.generate(posto: "frigo", nome: "6 uova"), {})[:places][1][:items].map { |i| i[:name] }
    assert_raises(ArgumentError) { @mod.api("POST", "aggiungi", "non json", {}) }
    assert_raises(ArgumentError) { @mod.api("POST", "aggiungi", JSON.generate(posto: "../etc", testo: "x"), {}) }
    assert_raises(ArgumentError) { @mod.api("GET", "aggiungi", "", {}) }
  end
end
