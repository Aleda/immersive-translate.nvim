---@diagnostic disable: undefined-global
-- Viewport scroll handling — design.md 6.3.
--
-- Rendering virt_lines pushes following content down, which changes botline
-- and fires WinScrolled again. Left unguarded that is a feedback loop: each
-- render pulls more paragraphs into view and the mode degrades into
-- translating the whole document. The guard is that only a change in
-- *topline* counts as a real scroll.

describe('immersive.viewport', function()
  local viewport

  before_each(function()
    package.loaded['comment-translate.immersive.viewport'] = nil
    viewport = require('comment-translate.immersive.viewport')
    viewport.reset()
  end)

  describe('topline guard', function()
    it('should treat the first observation as a scroll', function()
      assert.is_true(viewport.should_reschedule(1000, 10))
    end)

    it('should ignore a repeat observation at the same topline', function()
      viewport.should_reschedule(1000, 10)

      assert.is_false(viewport.should_reschedule(1000, 10))
    end)

    it('should treat a changed topline as a real scroll', function()
      viewport.should_reschedule(1000, 10)

      assert.is_true(viewport.should_reschedule(1000, 25))
    end)

    it('should ignore render-induced reflow at a stable topline', function()
      viewport.should_reschedule(1000, 10)

      -- A render extends the window's botline but leaves topline alone.
      assert.is_false(viewport.should_reschedule(1000, 10))
      assert.is_false(viewport.should_reschedule(1000, 10))
    end)

    it('should track windows independently', function()
      viewport.should_reschedule(1000, 10)
      viewport.should_reschedule(1001, 40)

      assert.is_false(viewport.should_reschedule(1000, 10))
      assert.is_false(viewport.should_reschedule(1001, 40))
      assert.is_true(viewport.should_reschedule(1000, 11))
    end)
  end)

  describe('forget', function()
    it('should drop a window entry so the next observation counts again', function()
      viewport.should_reschedule(1000, 10)
      assert.is_false(viewport.should_reschedule(1000, 10))

      viewport.forget(1000)

      assert.is_true(viewport.should_reschedule(1000, 10))
    end)

    it('should not leak entries for closed windows', function()
      viewport.should_reschedule(1000, 10)
      viewport.should_reschedule(1001, 10)

      viewport.forget(1000)

      assert.equals(1, viewport.tracked_count())
    end)
  end)

  describe('reset', function()
    it('should clear every tracked window', function()
      viewport.should_reschedule(1000, 10)
      viewport.should_reschedule(1001, 20)

      viewport.reset()

      assert.equals(0, viewport.tracked_count())
    end)
  end)
end)
