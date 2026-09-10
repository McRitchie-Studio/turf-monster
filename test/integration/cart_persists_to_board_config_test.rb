require "test_helper"

# [component] The cart -> #board-config write-back is WIRED on the contest page.
#
# selectionBoard() re-inits from #board-config on every Turbo restoration visit.
# That blob is rendered server-side and used to be frozen there, so a Back
# replayed the cart as of the last server render and dropped every pick made
# since. persistCartToConfig() hands the live cart to the snapshot instead.
#
# What this tier can prove: the method exists, it is bound to the event that
# matters, and the blob still has the keys it rewrites. What it cannot prove is
# that the round trip works — that needs a real Turbo restoration visit and a
# real Alpine re-init, which is e2e/cart_survives_turbo_restore.spec.js's job
# (three cases there: signed-in, pick-identity, and guest).
#
# It is worth having anyway because the two halves live ~1200 lines apart in the
# same partial: the binding sits on the x-data root, the method down in the
# factory. Renaming or deleting one half is silent, and the symptom it brings
# back is a cart that empties itself on Back.
class CartPersistsToBoardConfigTest < ActionDispatch::IntegrationTest
  setup do
    get contest_path(contests(:one))
    assert_response :success
    @html = response.body
  end

  test "the board root listens for turbo:before-cache" do
    assert_includes @html, %(@turbo:before-cache.window="persistCartToConfig()"),
                    "without this binding the live cart never reaches the snapshot " \
                    "and a Back navigation restores an empty sidebar"
  end

  test "the factory defines the method the binding calls" do
    assert_includes @html, "persistCartToConfig() {",
                    "the binding is only as good as the method it names"
  end

  test "the binding and the definition agree — neither half renamed alone" do
    # Exactly two mentions: the x-data binding and the factory definition. They
    # sit ~1200 lines apart, so renaming one and not the other is an easy miss
    # and produces no error — just a silently dead listener.
    assert_equal 2, @html.scan("persistCartToConfig").length,
                 "expected the binding and the definition, and nothing else"
  end

  test "the blob still carries the keys the method rewrites" do
    config = @html[/<script type="application\/json" id="board-config">(.*?)<\/script>/m, 1]
    assert config, "the contest page must render #board-config"

    parsed = JSON.parse(config)
    assert parsed.key?("cartSelections"),
           "persistCartToConfig() overwrites cartSelections — renaming the key " \
           "server-side would leave the write-back pointing at nothing"
    assert parsed.key?("cartSelectionOrder"),
           "and cartSelectionOrder, which carries the replace-oldest ordering"
  end
end
