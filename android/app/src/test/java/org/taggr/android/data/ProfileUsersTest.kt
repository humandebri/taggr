package org.taggr.android.data

import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.Assert.*
import org.junit.Test
import org.taggr.android.ProfileUserList

class ProfileUsersTest {
    @Test
    fun listsAreSortedUniqueAndFollowingExcludesOwner() {
        val profile =
            ObjectMapper()
                .readTree(
                    """{"id":7,"followees":[9,7,3,9,-1,1.5,"4",18446744073709551615,9007199254740990],"followers":[7,2,2]}"""
                )
        assertEquals(listOf(3L, 9L), ProfileUserList.Following.ids(profile))
        assertEquals(listOf(2L, 7L), ProfileUserList.Followers.ids(profile))
    }

    @Test
    fun absentListsAreEmpty() {
        val profile = ObjectMapper().readTree("""{"id":7}""")
        assertTrue(ProfileUserList.Followers.ids(profile).isEmpty())
        assertTrue(ProfileUserList.Following.ids(profile).isEmpty())
    }
}
